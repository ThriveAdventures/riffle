import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private enum IconState { case idle, recording, processing }

    // One dictation from hotkey press to inserted text. Jobs are numbered so
    // results insert in the order they were spoken, even when a new
    // recording starts while earlier ones are still processing.
    private final class DictationJob {
        let seq: Int
        let app: String?
        let editMode: Bool
        var selection: String?
        var presavedClipboard: TextInserter.ClipboardSnapshot?

        init(seq: Int, app: String?, editMode: Bool) {
            self.seq = seq
            self.app = app
            self.editMode = editMode
        }
    }

    private struct InsertPayload {
        let text: String
        let raw: String
        let editMode: Bool
        let usedLLM: Bool
        let seconds: Double
        let transcribeMs: Int
        let cleanupMs: Int
        let app: String?
        let presavedClipboard: TextInserter.ClipboardSnapshot?
    }

    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyManager()
    private let hud = HUD()
    private var config = RiffleConfig.load()
    private var whisper: WhisperService!
    private var ollama: OllamaClient!

    private var recorder: AudioRecorder?
    private var currentJob: DictationJob?
    private var handsFree = false
    private var ignoreNextUp = false
    private var pressStart = Date.distantPast

    private var seqCounter = 0
    private var nextInsertSeq = 0
    private var completed: [Int: InsertPayload?] = [:]
    private var processingCount = 0

    private var micGranted = false
    private var axGranted = false
    private var whisperUp = false
    private var ollamaUp = false
    private var ollamaHasModel = false
    private var spawnedOllama: Process?

    private var axPollTimer: Timer?
    private var healthTimer: Timer?

    private var hintItem: NSMenuItem!
    private var whisperLine: NSMenuItem!
    private var cleanupLine: NSMenuItem!
    private var cleanupToggle: NSMenuItem!
    private var loginToggle: NSMenuItem!
    private var axItem: NSMenuItem!
    private var micItem: NSMenuItem!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("riffle starting, pid \(ProcessInfo.processInfo.processIdentifier)")
        enforceSingleInstance()
        config.save()  // materialize config.json with defaults on first run

        // Services and hotkey state must exist before the menu is built:
        // refreshMenuState() reads them.
        whisper = WhisperService(config: config)
        whisper.startIfNeeded()
        ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
        wireHotkey()
        setupStatusItem()

        AudioRecorder.requestMicAccess { [weak self] ok in
            guard let self else { return }
            micGranted = ok
            Log.write("microphone permission: \(ok)")
            refreshMenuState()
        }

        checkAccessibility(promptUser: true)
        startHotkeyIfPossible()

        Task { await self.ensureOllama() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshHealth()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshHealth()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisper?.shutdown()
        spawnedOllama?.terminate()
        Log.write("riffle stopped")
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            Log.write("another instance is already running, quitting")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Permissions

    private func checkAccessibility(promptUser: Bool) {
        if promptUser {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            axGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            axGranted = AXIsProcessTrusted()
        }
        Log.write("accessibility permission: \(axGranted)")
        if !axGranted, axPollTimer == nil {
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, AXIsProcessTrusted() else { return }
                axGranted = true
                axPollTimer?.invalidate()
                axPollTimer = nil
                Log.write("accessibility granted")
                startHotkeyIfPossible()
                refreshMenuState()
            }
        }
    }

    private func startHotkeyIfPossible() {
        guard axGranted, !hotkey.isRunning else { return }
        if hotkey.start() {
            Log.write("hotkey listening: \(hotkey.key.displayName)")
        } else {
            Log.write("hotkey: event tap creation failed")
        }
        refreshMenuState()
    }

    // MARK: - Hotkey handling

    private func wireHotkey() {
        hotkey.key = HotkeyManager.HotKey.parse(config.hotkey)
        hotkey.onDown = { [weak self] shiftHeld in
            guard let self else { return }
            if recorder != nil {
                if handsFree {
                    ignoreNextUp = true
                    stopAndProcess()
                }
                return
            }
            pressStart = Date()
            startRecording(editMode: shiftHeld)
        }
        hotkey.onUp = { [weak self] in
            guard let self else { return }
            if ignoreNextUp {
                ignoreNextUp = false
                return
            }
            guard recorder != nil, !handsFree else { return }
            let duration = Date().timeIntervalSince(pressStart)
            if duration < 0.35 {
                handsFree = true
                hud.showListening(handsFree: true, edit: currentJob?.editMode ?? false)
            } else {
                stopAndProcess()
            }
        }
        hotkey.onCancel = { [weak self] in
            self?.cancelRecording()
        }
    }

    // MARK: - Recording flow

    private func startRecording(editMode: Bool) {
        guard micGranted else {
            hud.flash("Grant Microphone access in System Settings", ok: false)
            AudioRecorder.requestMicAccess { [weak self] ok in
                self?.micGranted = ok
                self?.refreshMenuState()
            }
            return
        }
        guard whisper.modelExists else {
            hud.flash("Whisper model missing, see menu", ok: false)
            return
        }
        if editMode {
            // Edit mode pastes over the user's selection, so a raw-transcript
            // fallback would destroy their text. Refuse instead.
            guard config.cleanupEnabled, ollamaUp, ollamaHasModel else {
                hud.flash("Edit mode needs AI cleanup available", ok: false)
                return
            }
        }

        let r = AudioRecorder()
        r.maxSeconds = config.maxRecordSeconds
        r.levelHandler = { [weak self] level in
            self?.hud.setLevel(level)
        }
        r.onAutoStop = { [weak self] in
            self?.stopAndProcess()
        }
        do {
            try r.start()
        } catch {
            Log.write("audio start failed: \(error.localizedDescription)")
            hud.flash("Could not start the microphone", ok: false)
            return
        }

        let job = DictationJob(seq: seqCounter,
                               app: NSWorkspace.shared.frontmostApplication?.localizedName,
                               editMode: editMode)
        seqCounter += 1
        if editMode {
            SelectionGrabber.grab { text, saved in
                job.selection = text
                job.presavedClipboard = saved
            }
        }

        recorder = r
        currentJob = job
        handsFree = false
        hotkey.capturing = true
        updateIcon()
        playSound("Pop")
        hud.showListening(handsFree: false, edit: editMode)
    }

    private func cancelRecording() {
        guard let r = recorder, let job = currentJob else { return }
        r.cancel()
        recorder = nil
        currentJob = nil
        handsFree = false
        hotkey.capturing = false
        finishSeq(job.seq, with: nil)
        updateIcon()
        hud.flash("Canceled", ok: false)
    }

    private func stopAndProcess() {
        guard let r = recorder, let job = currentJob else { return }
        recorder = nil
        currentJob = nil
        handsFree = false
        hotkey.capturing = false
        playSound("Tink")

        let recording = r.stop()
        guard let recording, recording.peak >= 0.006 else {
            if let recording { try? FileManager.default.removeItem(at: recording.url) }
            hud.flash("Nothing heard", ok: false)
            finishSeq(job.seq, with: nil)
            updateIcon()
            return
        }

        processingCount += 1
        updateIcon()
        hud.showProcessing()
        Task { await self.process(recording, job: job) }
    }

    private func process(_ recording: AudioRecorder.Recording, job: DictationJob) async {
        let t0 = Date()
        var raw: String
        do {
            raw = try await whisper.transcribe(wavURL: recording.url)
        } catch {
            Log.write("transcribe failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: recording.url)
            await MainActor.run {
                flashIfIdle("Transcription failed, check the log", ok: false)
                whisper.startIfNeeded()
                finishProcessing(job.seq, with: nil)
                refreshHealth()
            }
            return
        }
        try? FileManager.default.removeItem(at: recording.url)
        let transcribeMs = Int(Date().timeIntervalSince(t0) * 1000)

        raw = TextCleanup.sanitizeWhisper(raw)
        guard !raw.isEmpty else {
            await MainActor.run {
                flashIfIdle("Nothing heard", ok: false)
                finishProcessing(job.seq, with: nil)
            }
            return
        }

        if job.editMode {
            await processEdit(raw: raw, job: job, seconds: recording.seconds,
                              transcribeMs: transcribeMs)
        } else {
            await processDictation(raw: raw, job: job, seconds: recording.seconds,
                                   transcribeMs: transcribeMs)
        }
    }

    private func processDictation(raw: String, job: DictationJob,
                                  seconds: Double, transcribeMs: Int) async {
        var finalText = TextCleanup.basicTidy(raw)
        var usedLLM = false
        var cleanupMs = 0
        if config.cleanupEnabled, ollamaUp, ollamaHasModel {
            let t1 = Date()
            do {
                let cleaned = try await ollama.cleanup(transcript: raw, appName: job.app,
                                                       dictionary: config.dictionary)
                let result = TextCleanup.guardrail(raw: finalText, cleaned: cleaned)
                finalText = result.0
                usedLLM = result.1
            } catch {
                Log.write("cleanup failed, inserting raw transcript: \(error.localizedDescription)")
            }
            cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)
        }

        finalText = TextCleanup.applyReplacements(finalText, rules: config.replacements)
        if config.trailingSpace, !finalText.hasSuffix("\n") {
            finalText += " "
        }

        let payload = InsertPayload(text: finalText, raw: raw, editMode: false,
                                    usedLLM: usedLLM, seconds: seconds,
                                    transcribeMs: transcribeMs, cleanupMs: cleanupMs,
                                    app: job.app, presavedClipboard: nil)
        await MainActor.run { finishProcessing(job.seq, with: payload) }
    }

    private func processEdit(raw: String, job: DictationJob,
                             seconds: Double, transcribeMs: Int) async {
        guard let selection = job.selection, !selection.isEmpty else {
            await MainActor.run {
                flashIfIdle("No text selected", ok: false)
                finishProcessing(job.seq, with: nil)
            }
            return
        }

        let t1 = Date()
        var edited: String?
        do {
            let out = try await ollama.edit(text: selection, instruction: raw,
                                            dictionary: config.dictionary)
            edited = TextCleanup.guardrailEdit(output: out)
        } catch {
            Log.write("edit failed: \(error.localizedDescription)")
        }
        let cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)

        guard var result = edited else {
            await MainActor.run {
                flashIfIdle("Edit failed, selection untouched", ok: false)
                finishProcessing(job.seq, with: nil)
            }
            return
        }
        result = TextCleanup.applyReplacements(result, rules: config.replacements)

        let payload = InsertPayload(text: result, raw: raw, editMode: true,
                                    usedLLM: true, seconds: seconds,
                                    transcribeMs: transcribeMs, cleanupMs: cleanupMs,
                                    app: job.app,
                                    presavedClipboard: job.presavedClipboard)
        await MainActor.run { finishProcessing(job.seq, with: payload) }
    }

    // MARK: - Ordered insertion queue

    private func finishProcessing(_ seq: Int, with payload: InsertPayload?) {
        processingCount = max(0, processingCount - 1)
        finishSeq(seq, with: payload)
        updateIcon()
        if recorder == nil, processingCount > 0 {
            hud.showProcessing()
        }
    }

    private func finishSeq(_ seq: Int, with payload: InsertPayload?) {
        completed[seq] = payload
        drainQueue()
    }

    private func drainQueue() {
        while let entry = completed[nextInsertSeq] {
            completed.removeValue(forKey: nextInsertSeq)
            nextInsertSeq += 1
            guard let p = entry else { continue }
            TextInserter.insert(text: p.text, mode: config.insertMode,
                                restoreClipboard: config.restoreClipboard,
                                presaved: config.restoreClipboard ? p.presavedClipboard : nil)
            if config.historyEnabled {
                History.append(raw: p.raw, cleaned: p.text, app: p.app,
                               seconds: p.seconds, transcribeMs: p.transcribeMs,
                               cleanupMs: p.cleanupMs, edit: p.editMode)
            }
            Log.write("\(p.editMode ? "edit" : "dictation"): \(String(format: "%.1f", p.seconds))s audio, whisper \(p.transcribeMs)ms, cleanup \(p.cleanupMs)ms, llm=\(p.usedLLM)")
            if p.editMode {
                flashIfIdle("Edited", ok: true)
            } else {
                flashIfIdle(p.usedLLM ? "Inserted" : "Inserted raw transcript", ok: true)
            }
        }
    }

    // Never stomp the Listening HUD of an in-progress recording with a
    // status flash for an earlier dictation.
    private func flashIfIdle(_ message: String, ok: Bool) {
        guard recorder == nil else { return }
        hud.flash(message, ok: ok)
    }

    private func updateIcon() {
        if recorder != nil {
            icon(.recording)
        } else if processingCount > 0 {
            icon(.processing)
        } else {
            icon(.idle)
        }
    }

    // MARK: - Ollama supervision

    private func ensureOllama() async {
        if await ollama.isUp() {
            ollamaUp = true
        } else {
            let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                              "/Applications/Ollama.app/Contents/Resources/ollama"]
            if let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["serve"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    spawnedOllama = p
                    Log.write("ollama: spawned \(bin) pid \(p.processIdentifier)")
                } catch {
                    Log.write("ollama: failed to spawn: \(error.localizedDescription)")
                }
                for _ in 0..<20 {
                    if await ollama.isUp() {
                        ollamaUp = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        if ollamaUp {
            ollamaHasModel = await ollama.hasModel()
            if ollamaHasModel {
                await ollama.preload()
            } else {
                Log.write("ollama: model \(ollama.model) not found, run: ollama pull \(ollama.model)")
            }
        }
        await MainActor.run { refreshMenuState() }
    }

    private func refreshHealth() {
        Task {
            let w = await whisper.isHealthy()
            let o = await ollama.isUp()
            var hasModel = ollamaHasModel
            if o, !hasModel {
                hasModel = await ollama.hasModel()
                if hasModel { await ollama.preload() }
            }
            let resolvedHasModel = hasModel
            await MainActor.run {
                whisperUp = w
                ollamaUp = o
                ollamaHasModel = resolvedHasModel
                if !w { whisper.startIfNeeded() }
                refreshMenuState()
            }
        }
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        icon(.idle)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        hintItem = infoItem("")
        menu.addItem(hintItem)
        whisperLine = infoItem("Whisper: starting")
        menu.addItem(whisperLine)
        cleanupLine = infoItem("AI cleanup: checking")
        menu.addItem(cleanupLine)
        menu.addItem(.separator())

        axItem = NSMenuItem(title: "Grant Accessibility permission (required)",
                            action: #selector(openAxSettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        micItem = NSMenuItem(title: "Grant Microphone permission (required)",
                             action: #selector(openMicSettings), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        cleanupToggle = NSMenuItem(title: "AI cleanup",
                                   action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupToggle.target = self
        menu.addItem(cleanupToggle)

        loginToggle = NSMenuItem(title: "Launch at login",
                                 action: #selector(toggleLoginItem), keyEquivalent: "")
        loginToggle.target = self
        menu.addItem(loginToggle)
        menu.addItem(.separator())

        menu.addItem(actionItem("Open config file", #selector(openConfig)))
        menu.addItem(actionItem("Reload config", #selector(reloadConfig)))
        menu.addItem(actionItem("Open history", #selector(openHistory)))
        menu.addItem(actionItem("Open log", #selector(openLog)))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Riffle",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkAccessibility(promptUser: false)
        startHotkeyIfPossible()
        refreshHealth()
        refreshMenuState()
    }

    private func refreshMenuState() {
        let keyName = hotkey.key.displayName
        hintItem.title = "Hold \(keyName) to dictate, shift+\(keyName) edits selected text"

        if !whisper.modelExists {
            whisperLine.title = "Whisper: model missing (run setup.sh)"
        } else if let err = whisper.lastError {
            whisperLine.title = "Whisper: \(err)"
        } else if whisperUp {
            whisperLine.title = "Whisper: ready"
        } else {
            whisperLine.title = "Whisper: starting"
        }

        if !config.cleanupEnabled {
            cleanupLine.title = "AI cleanup: off (raw transcripts)"
        } else if ollamaUp && ollamaHasModel {
            cleanupLine.title = "AI cleanup: \(config.llmModel)"
        } else if ollamaUp {
            cleanupLine.title = "AI cleanup: model missing, run: ollama pull \(config.llmModel)"
        } else {
            cleanupLine.title = "AI cleanup: Ollama not reachable"
        }

        axItem.isHidden = axGranted
        micItem.isHidden = micGranted
        cleanupToggle.state = config.cleanupEnabled ? .on : .off
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginToggle.isEnabled = Bundle.main.bundleIdentifier != nil
    }

    // MARK: - Menu actions

    @objc private func toggleCleanup() {
        config.cleanupEnabled.toggle()
        config.save()
        refreshMenuState()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        refreshMenuState()
    }

    @objc private func openAxSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openMicSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfig() {
        config.save()
        NSWorkspace.shared.open(RiffleConfig.fileURL)
    }

    @objc private func reloadConfig() {
        config = RiffleConfig.load()
        hotkey.key = HotkeyManager.HotKey.parse(config.hotkey)
        whisper.shutdown()
        whisper = WhisperService(config: config)
        whisper.startIfNeeded()
        ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
        ollamaHasModel = false
        Task { await self.ensureOllama() }
        Log.write("config reloaded")
        refreshMenuState()
    }

    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: History.url.path) {
            try? Data().write(to: History.url)
        }
        NSWorkspace.shared.open(History.url)
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.file.path) {
            try? Data().write(to: Log.file)
        }
        NSWorkspace.shared.open(Log.file)
    }

    // MARK: - Status icon and sounds

    private func icon(_ s: IconState) {
        let name: String
        var tint: NSColor?
        switch s {
        case .idle:
            name = "waveform"
        case .recording:
            name = "record.circle.fill"
            tint = .systemRed
        case .processing:
            name = "hourglass"
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "Riffle") else { return }
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = tint
    }

    private func playSound(_ name: String) {
        guard config.sounds else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}

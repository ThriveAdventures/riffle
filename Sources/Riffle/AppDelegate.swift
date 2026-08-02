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
        let appIcon: NSImage?
        let editMode: Bool
        var selection: String?
        var presavedClipboard: TextInserter.ClipboardSnapshot?

        init(seq: Int, app: String?, appIcon: NSImage?, editMode: Bool) {
            self.seq = seq
            self.app = app
            self.appIcon = appIcon
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

    private let audio = AudioRecorder()
    private var currentJob: DictationJob?
    private var handsFree = false
    private var handsFreeEngagedAt = Date.distantPast
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

    // Meeting recording (macOS 14.2+). Stored untyped so the class itself
    // stays available on the 13.0 floor.
    private var meetingBox: AnyObject?
    private var meetingActive = false
    private var meetingStartedAt = Date.distantPast

    private var hintItem: NSMenuItem!
    private var whisperLine: NSMenuItem!
    private var cleanupLine: NSMenuItem!
    private var cleanupToggle: NSMenuItem!
    private var engineOllamaItem: NSMenuItem!
    private var engineAppleItem: NSMenuItem!
    private var meetingToggle: NSMenuItem!
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

        audio.spectrumHandler = { [weak self] bands in
            self?.hud.setSpectrum(bands)
        }
        audio.onAutoStop = { [weak self] in
            self?.stopAndProcess()
        }
        AudioRecorder.requestMicAccess { [weak self] ok in
            guard let self else { return }
            micGranted = ok
            Log.write("microphone permission: \(ok)")
            if ok { audio.warmup() }
            refreshMenuState()
        }

        checkAccessibility(promptUser: true)
        startHotkeyIfPossible()
        syncLoginItem()

        if config.cleanupEngine == "ollama" {
            Task { await self.ensureOllama() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.audio.watchdog()
            self?.refreshHealth()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshHealth()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 14.2, *), let recorder = meetingBox as? MeetingRecorder {
            _ = recorder.stop()
        }
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
        hotkey.onDown = { [weak self] shiftHeld, at in
            guard let self else { return }
            if currentJob != nil {
                if handsFree {
                    // Debounce: no human re-taps within a quarter second of
                    // engaging hands-free. Synthetic duplicate events from
                    // the fn/Globe layer must not stop the recording.
                    guard at.timeIntervalSince(handsFreeEngagedAt) > 0.25 else {
                        ignoreNextUp = true
                        return
                    }
                    ignoreNextUp = true
                    stopAndProcess()
                }
                return
            }
            pressStart = at
            startRecording(editMode: shiftHeld)
        }
        hotkey.onUp = { [weak self] at in
            guard let self else { return }
            if ignoreNextUp {
                ignoreNextUp = false
                return
            }
            guard currentJob != nil, !handsFree else { return }
            let duration = at.timeIntervalSince(pressStart)
            // Generous tap window: no one dictates in under 0.6s of
            // holding, and taps right at a tighter boundary misclassify
            // as hold-releases that instantly stop the recording.
            if duration < 0.6 {
                handsFree = true
                handsFreeEngagedAt = at
                hud.showListening(handsFree: true, edit: currentJob?.editMode ?? false,
                                  appIcon: currentJob?.appIcon)
            } else {
                stopAndProcess()
            }
        }
        hotkey.onCancel = { [weak self] in
            self?.cancelRecording()
        }
    }

    private var cleanupReady: Bool {
        guard config.cleanupEnabled else { return false }
        return config.cleanupEngine == "apple"
            ? AppleCleaner.isAvailable
            : (ollamaUp && ollamaHasModel)
    }

    private func engineCleanup(_ raw: String, app: String?) async throws -> String {
        if config.cleanupEngine == "apple" {
            return try await AppleCleaner.cleanup(transcript: raw, appName: app,
                                                  dictionary: config.dictionary)
        }
        return try await ollama.cleanup(transcript: raw, appName: app,
                                        dictionary: config.dictionary)
    }

    private func engineEdit(text: String, instruction: String) async throws -> String {
        if config.cleanupEngine == "apple" {
            return try await AppleCleaner.edit(text: text, instruction: instruction,
                                               dictionary: config.dictionary)
        }
        return try await ollama.edit(text: text, instruction: instruction,
                                     dictionary: config.dictionary)
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
            guard cleanupReady else {
                hud.flash("Edit mode needs AI cleanup available", ok: false)
                return
            }
        }

        audio.maxSeconds = config.maxRecordSeconds
        do {
            try audio.start()
        } catch {
            Log.write("audio start failed: \(error.localizedDescription)")
            hud.flash("Could not start the microphone", ok: false)
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let job = DictationJob(seq: seqCounter,
                               app: frontmost?.localizedName,
                               appIcon: frontmost?.icon,
                               editMode: editMode)
        seqCounter += 1
        if editMode {
            SelectionGrabber.grab { text, saved in
                job.selection = text
                job.presavedClipboard = saved
            }
        }

        currentJob = job
        handsFree = false
        hotkey.capturing = true
        updateIcon()
        playSound("Pop")
        hud.showListening(handsFree: false, edit: editMode, appIcon: job.appIcon, prime: true)
    }

    private func cancelRecording() {
        guard let job = currentJob else { return }
        audio.cancel()
        currentJob = nil
        handsFree = false
        hotkey.capturing = false
        finishSeq(job.seq, with: nil)
        updateIcon()
        hud.flash("Canceled", ok: false)
    }

    private func stopAndProcess() {
        guard let job = currentJob else { return }
        currentJob = nil
        handsFree = false
        hotkey.capturing = false
        playSound("Tink")

        let recording = audio.stop()
        guard let recording, recording.peak >= 0.006 else {
            if let recording {
                Log.write("nothing heard: \(String(format: "%.2f", recording.seconds))s audio, peak \(String(format: "%.4f", recording.peak)) (silent input?)")
                try? FileManager.default.removeItem(at: recording.url)
            } else {
                Log.write("nothing heard: recording under minimum duration")
            }
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
        if cleanupReady {
            let t1 = Date()
            do {
                let cleaned = try await engineCleanup(raw, app: job.app)
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
            let out = try await engineEdit(text: selection, instruction: raw)
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
        if currentJob == nil, processingCount > 0 {
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
                flashIfIdle("Edited" + celebrationSuffix(edit: true), ok: true)
            } else {
                flashIfIdle((p.usedLLM ? "Inserted" : "Inserted raw transcript")
                            + celebrationSuffix(edit: false), ok: true)
            }
        }
    }

    // Occasional emoji on success flashes. Curated, rare enough to stay a
    // treat. Config "fun": false turns it off.
    private func celebrationSuffix(edit: Bool) -> String {
        guard config.fun, Double.random(in: 0..<1) < 0.4 else { return "" }
        let common = edit ? ["\u{2728}", "\u{1FA84}", "\u{2702}\u{FE0F}"]
                          : ["\u{2728}", "\u{1F30A}", "\u{270D}\u{FE0F}", "\u{26A1}\u{FE0F}", "\u{1F3AF}"]
        let rare = ["\u{1F6F6}", "\u{1F341}", "\u{1F9AB}"]
        let pool = Double.random(in: 0..<1) < 0.15 ? rare : common
        guard let pick = pool.randomElement() else { return "" }
        return "  " + pick
    }

    // Never stomp the Listening HUD of an in-progress recording with a
    // status flash for an earlier dictation.
    private func flashIfIdle(_ message: String, ok: Bool) {
        guard currentJob == nil else { return }
        hud.flash(message, ok: ok)
    }

    private func updateIcon() {
        if currentJob != nil {
            icon(.recording)
        } else if processingCount > 0 {
            icon(.processing)
        } else if meetingActive {
            statusItem.button?.image = Self.menuBarMark
            statusItem.button?.contentTintColor = .systemBlue
        } else {
            icon(.idle)
        }
    }

    // MARK: - Meeting recording

    @objc private func toggleMeeting() {
        guard #available(macOS 14.2, *) else { return }
        if meetingActive {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    @available(macOS 14.2, *)
    private func startMeeting() {
        let recorder = MeetingRecorder()
        do {
            try recorder.start()
        } catch {
            Log.write("meeting: start failed: \(error.localizedDescription)")
            hud.flash("Meeting recording failed, check permissions", ok: false)
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
            NSWorkspace.shared.open(url)
            return
        }
        meetingBox = recorder
        meetingActive = true
        meetingStartedAt = Date()
        updateIcon()
        refreshMenuState()
        hud.flash("Meeting recording started", ok: true)
        playSound("Pop")
    }

    @available(macOS 14.2, *)
    private func stopMeeting() {
        guard let recorder = meetingBox as? MeetingRecorder else { return }
        meetingBox = nil
        meetingActive = false
        updateIcon()
        playSound("Tink")
        guard let tracks = recorder.stop() else {
            hud.flash("Meeting produced no audio", ok: false)
            refreshMenuState()
            return
        }
        hud.flash("Transcribing meeting, this can take a bit", ok: true)
        Task { await self.processMeeting(tracks) }
        refreshMenuState()
    }

    @available(macOS 14.2, *)
    private func processMeeting(_ tracks: MeetingRecorder.Tracks) async {
        var micSegments: [WhisperService.Segment] = []
        var systemSegments: [WhisperService.Segment] = []
        do {
            micSegments = try await whisper.transcribeSegments(wavURL: tracks.micWav)
        } catch {
            Log.write("meeting: mic transcription failed: \(error.localizedDescription)")
        }
        do {
            systemSegments = try await whisper.transcribeSegments(wavURL: tracks.systemWav)
        } catch {
            Log.write("meeting: system transcription failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: tracks.micWav)
        try? FileManager.default.removeItem(at: tracks.systemWav)

        guard !micSegments.isEmpty || !systemSegments.isEmpty else {
            await MainActor.run { hud.flash("Meeting had no transcribable speech", ok: false) }
            return
        }
        let transcript = MeetingNotes.mergedTranscript(mic: micSegments, system: systemSegments)

        var summary: String?
        if await ollama.isUp(), await ollama.hasModel() {
            summary = try? await ollama.summarizeMeeting(transcript: transcript,
                                                         minutes: max(1, Int(tracks.seconds / 60)))
        }

        let md = MeetingNotes.build(transcript: transcript, seconds: tracks.seconds, summary: summary)
        do {
            let url = try MeetingNotes.save(md)
            Log.write("meeting: notes saved to \(url.path)")
            await MainActor.run {
                hud.flash("Meeting notes saved", ok: true)
                NSWorkspace.shared.open(url)
            }
        } catch {
            Log.write("meeting: save failed: \(error.localizedDescription)")
            await MainActor.run { hud.flash("Could not save meeting notes", ok: false) }
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
                if hasModel, config.cleanupEngine == "ollama" { await ollama.preload() }
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

        let engineMenu = NSMenu()
        engineMenu.autoenablesItems = false
        engineOllamaItem = NSMenuItem(title: "Local model (Ollama)",
                                      action: #selector(selectEngineOllama), keyEquivalent: "")
        engineOllamaItem.target = self
        engineMenu.addItem(engineOllamaItem)
        engineAppleItem = NSMenuItem(title: "Apple on-device (Foundation Models)",
                                     action: #selector(selectEngineApple), keyEquivalent: "")
        engineAppleItem.target = self
        engineMenu.addItem(engineAppleItem)
        let engineParent = NSMenuItem(title: "Cleanup engine", action: nil, keyEquivalent: "")
        engineParent.submenu = engineMenu
        menu.addItem(engineParent)

        meetingToggle = NSMenuItem(title: "Start meeting recording",
                                   action: #selector(toggleMeeting), keyEquivalent: "")
        meetingToggle.target = self
        menu.addItem(meetingToggle)

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
        } else if config.cleanupEngine == "apple" {
            cleanupLine.title = AppleCleaner.isAvailable
                ? "AI cleanup: Apple on-device"
                : "AI cleanup: Apple engine \(AppleCleaner.availabilityDescription)"
        } else if ollamaUp && ollamaHasModel {
            cleanupLine.title = "AI cleanup: \(config.llmModel)"
        } else if ollamaUp {
            cleanupLine.title = "AI cleanup: model missing, run: ollama pull \(config.llmModel)"
        } else {
            cleanupLine.title = "AI cleanup: Ollama not reachable"
        }
        engineOllamaItem.title = "Local model (\(config.llmModel))"
        engineOllamaItem.state = config.cleanupEngine == "ollama" ? .on : .off
        let appleAvailable = AppleCleaner.isAvailable
        engineAppleItem.isEnabled = appleAvailable
        engineAppleItem.state = config.cleanupEngine == "apple" ? .on : .off
        engineAppleItem.title = appleAvailable
            ? "Apple on-device (Foundation Models)"
            : "Apple on-device (\(AppleCleaner.availabilityDescription))"

        if meetingActive {
            let elapsed = Int(Date().timeIntervalSince(meetingStartedAt))
            meetingToggle.title = String(format: "Stop meeting recording (%d:%02d)", elapsed / 60, elapsed % 60)
        } else {
            meetingToggle.title = "Start meeting recording"
        }
        if #available(macOS 14.2, *) {
            meetingToggle.isEnabled = true
        } else {
            meetingToggle.isEnabled = false
            meetingToggle.title = "Meeting recording needs macOS 14.2+"
        }
        axItem.isHidden = axGranted
        micItem.isHidden = micGranted
        cleanupToggle.state = config.cleanupEnabled ? .on : .off
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginToggle.isEnabled = Bundle.main.bundleIdentifier != nil
    }

    // MARK: - Menu actions

    @objc private func selectEngineOllama() { setEngine("ollama") }
    @objc private func selectEngineApple() { setEngine("apple") }

    private func setEngine(_ engine: String) {
        guard config.cleanupEngine != engine else { return }
        config.cleanupEngine = engine
        config.save()
        Log.write("cleanup engine: \(engine)")
        if engine == "apple" {
            Task {
                await ollama.unload()
                await MainActor.run { self.refreshMenuState() }
            }
        } else {
            Task { await self.ensureOllama() }
        }
        refreshMenuState()
    }

    @objc private func toggleCleanup() {
        config.cleanupEnabled.toggle()
        config.save()
        refreshMenuState()
    }

    @objc private func toggleLoginItem() {
        config.launchAtLogin = SMAppService.mainApp.status != .enabled
        config.save()
        do {
            if config.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        refreshMenuState()
    }

    // Riffle should survive restarts by default; register as a login item
    // unless the user opted out.
    private func syncLoginItem() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let enabled = SMAppService.mainApp.status == .enabled
        do {
            if config.launchAtLogin, !enabled {
                try SMAppService.mainApp.register()
                Log.write("login item: registered (launch at login on)")
            } else if !config.launchAtLogin, enabled {
                try SMAppService.mainApp.unregister()
                Log.write("login item: unregistered per config")
            }
        } catch {
            Log.write("login item: sync failed: \(error.localizedDescription)")
        }
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

    // The brand mark drawn as a template image: scope ring, four posts, five
    // bars. Drawn in code so it stays crisp at any backing scale and adapts
    // to menu bar appearance. State is carried by tint.
    private static let menuBarMark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            ring.lineWidth = 1.2
            ring.stroke()
            let posts = [
                NSRect(x: 8.4, y: 14.2, width: 1.2, height: 1.3),
                NSRect(x: 8.4, y: 2.5, width: 1.2, height: 1.3),
                NSRect(x: 2.5, y: 8.4, width: 1.3, height: 1.2),
                NSRect(x: 14.2, y: 8.4, width: 1.3, height: 1.2),
            ]
            for rect in posts {
                NSBezierPath(roundedRect: rect, xRadius: 0.4, yRadius: 0.4).fill()
            }
            let heights: [CGFloat] = [2.6, 5.2, 8.0, 5.2, 2.6]
            for (i, h) in heights.enumerated() {
                let cx = 9.0 + CGFloat(i - 2) * 2.0
                let rect = NSRect(x: cx - 0.65, y: 9 - h / 2, width: 1.3, height: h)
                NSBezierPath(roundedRect: rect, xRadius: 0.65, yRadius: 0.65).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func icon(_ s: IconState) {
        let tint: NSColor?
        switch s {
        case .idle: tint = nil
        case .recording: tint = .systemRed
        case .processing: tint = .systemGray
        }
        statusItem.button?.image = Self.menuBarMark
        statusItem.button?.contentTintColor = tint
    }

    private func playSound(_ name: String) {
        guard config.sounds else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}

import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private enum RunState { case idle, recording, processing }
    private enum IconState { case idle, recording, processing }

    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyManager()
    private var recorder: AudioRecorder?
    private let hud = HUD()
    private var config = RiffleConfig.load()
    private var whisper: WhisperService!
    private var ollama: OllamaClient!

    private var state: RunState = .idle
    private var handsFree = false
    private var ignoreNextUp = false
    private var pressStart = Date.distantPast
    private var targetApp: String?

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
        hotkey.onDown = { [weak self] in
            guard let self else { return }
            switch state {
            case .recording:
                if handsFree {
                    ignoreNextUp = true
                    stopAndProcess()
                }
            case .processing:
                ignoreNextUp = true
                hud.flash("Still finishing the last one", ok: false)
            case .idle:
                pressStart = Date()
                startRecording()
            }
        }
        hotkey.onUp = { [weak self] in
            guard let self else { return }
            if ignoreNextUp {
                ignoreNextUp = false
                return
            }
            guard state == .recording, !handsFree else { return }
            let duration = Date().timeIntervalSince(pressStart)
            if duration < 0.35 {
                handsFree = true
                hud.showListening(handsFree: true)
            } else {
                stopAndProcess()
            }
        }
        hotkey.onCancel = { [weak self] in
            self?.cancelRecording()
        }
    }

    private func setState(_ s: RunState) {
        state = s
        hotkey.capturing = (s == .recording)
        switch s {
        case .idle: icon(.idle)
        case .recording: icon(.recording)
        case .processing: icon(.processing)
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
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

        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
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
            recorder = r
            handsFree = false
            setState(.recording)
            playSound("Pop")
            hud.showListening(handsFree: false)
        } catch {
            Log.write("audio start failed: \(error.localizedDescription)")
            hud.flash("Could not start the microphone", ok: false)
        }
    }

    private func cancelRecording() {
        guard state == .recording, let r = recorder else { return }
        r.cancel()
        recorder = nil
        handsFree = false
        setState(.idle)
        hud.flash("Canceled", ok: false)
    }

    private func stopAndProcess() {
        guard state == .recording, let r = recorder else { return }
        setState(.processing)
        playSound("Tink")
        let recording = r.stop()
        recorder = nil
        handsFree = false

        guard let recording else {
            hud.flash("Nothing heard", ok: false)
            setState(.idle)
            return
        }
        if recording.peak < 0.006 {
            try? FileManager.default.removeItem(at: recording.url)
            hud.flash("Nothing heard", ok: false)
            setState(.idle)
            return
        }

        hud.showProcessing()
        let app = targetApp
        Task { await self.process(recording, app: app) }
    }

    private func process(_ recording: AudioRecorder.Recording, app: String?) async {
        let t0 = Date()
        var raw: String
        do {
            raw = try await whisper.transcribe(wavURL: recording.url)
        } catch {
            Log.write("transcribe failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: recording.url)
            await MainActor.run {
                hud.flash("Transcription failed, check the log", ok: false)
                setState(.idle)
                whisper.startIfNeeded()
                refreshHealth()
            }
            return
        }
        try? FileManager.default.removeItem(at: recording.url)
        let transcribeMs = Int(Date().timeIntervalSince(t0) * 1000)

        raw = TextCleanup.sanitizeWhisper(raw)
        guard !raw.isEmpty else {
            await MainActor.run {
                hud.flash("Nothing heard", ok: false)
                setState(.idle)
            }
            return
        }

        var finalText = TextCleanup.basicTidy(raw)
        var usedLLM = false
        var cleanupMs = 0
        if config.cleanupEnabled, ollamaUp, ollamaHasModel {
            let t1 = Date()
            do {
                let cleaned = try await ollama.cleanup(transcript: raw, appName: app,
                                                       dictionary: config.dictionary)
                let result = TextCleanup.guardrail(raw: finalText, cleaned: cleaned)
                finalText = result.0
                usedLLM = result.1
            } catch {
                Log.write("cleanup failed, inserting raw transcript: \(error.localizedDescription)")
            }
            cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)
        }

        if config.trailingSpace, !finalText.hasSuffix("\n") {
            finalText += " "
        }

        let out = finalText
        let rawFinal = raw
        let stats = (transcribeMs, cleanupMs, usedLLM)
        await MainActor.run {
            TextInserter.insert(text: out, mode: config.insertMode,
                                restoreClipboard: config.restoreClipboard)
            if config.historyEnabled {
                History.append(raw: rawFinal, cleaned: out, app: app,
                               seconds: recording.seconds,
                               transcribeMs: stats.0, cleanupMs: stats.1)
            }
            Log.write("dictation: \(String(format: "%.1f", recording.seconds))s audio, whisper \(stats.0)ms, cleanup \(stats.1)ms, llm=\(stats.2)")
            hud.flash(stats.2 ? "Inserted" : "Inserted raw transcript", ok: true)
            setState(.idle)
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
        hintItem.title = "Hold \(keyName) to dictate, quick-tap for hands-free, esc cancels"

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

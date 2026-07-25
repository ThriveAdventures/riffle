import Foundation

// Headless text-pipeline check: riffle --cleantest "raw transcript" [app name]
// Runs the LLM cleanup, guardrails, and word replacements on the given text.
func runCleanTest(raw: String, app: String?) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        defer { semaphore.signal() }
        let config = RiffleConfig.load()
        let ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
        guard await ollama.isUp(), await ollama.hasModel() else {
            print("FAIL: ollama or model \(config.llmModel) unavailable")
            return
        }
        do {
            let cleaned = try await ollama.cleanup(transcript: raw, appName: app,
                                                   dictionary: config.dictionary)
            let result = TextCleanup.guardrail(raw: TextCleanup.basicTidy(raw), cleaned: cleaned)
            let final = TextCleanup.applyReplacements(result.0, rules: config.replacements)
            print("llm=\(result.1)")
            print("cleaned: \(result.0)")
            print("final:   \(final)")
            code = 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
        }
    }
    semaphore.wait()
    return code
}

// Headless edit-mode check: riffle --edittest "text" "instruction"
func runEditTest(text: String, instruction: String) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        defer { semaphore.signal() }
        let config = RiffleConfig.load()
        let ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
        guard await ollama.isUp(), await ollama.hasModel() else {
            print("FAIL: ollama or model \(config.llmModel) unavailable")
            return
        }
        do {
            let out = try await ollama.edit(text: text, instruction: instruction,
                                            dictionary: config.dictionary)
            guard let safe = TextCleanup.guardrailEdit(output: out) else {
                print("REJECTED by guardrail, raw output:\n\(out)")
                return
            }
            let final = TextCleanup.applyReplacements(safe, rules: config.replacements)
            print("edited:\n\(final)")
            code = 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
        }
    }
    semaphore.wait()
    return code
}

// Visual check: riffle --hudtest [output-prefix]
// Cycles the HUD through listening, processing, and flash states with a
// synthetic level signal. With an output prefix, captures its own window
// (shadow included) to PNG at each state; own-window capture needs no
// screen-recording permission.
import AppKit
import ImageIO
import UniformTypeIdentifiers

func runHudTest(capturePrefix: String?) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let hud = HUD()
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/Riffle.app")
    hud.showListening(handsFree: false, appIcon: icon, prime: true)
    var t: Double = 0
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        t += 0.05
        var bands = [Float](repeating: 0, count: 12)
        for b in 0..<12 {
            bands[b] = Float(abs(sin(t * 2.9 + Double(b) * 0.65)) * (0.25 + 0.6 * abs(sin(t * 1.4))))
        }
        hud.setSpectrum(bands)
        if let prefix = capturePrefix {
            if t >= 1.5, t < 1.55 { captureWindow(hud.testWindow, to: "\(prefix)-listening.png") }
            if t >= 3.5, t < 3.55 { captureWindow(hud.testWindow, to: "\(prefix)-handsfree.png") }
            if t >= 5.0, t < 5.05 { captureWindow(hud.testWindow, to: "\(prefix)-processing.png") }
            if t >= 7.6, t < 7.65 { captureWindow(hud.testWindow, to: "\(prefix)-flash.png") }
        }
        if t >= 2.8, t < 2.85 { hud.showListening(handsFree: true, appIcon: icon) }
        if t >= 4.0, t < 4.05 { hud.showProcessing() }
        if t >= 7.0, t < 7.05 { hud.flash("Inserted", ok: true) }
        if t >= 9 { exit(0) }
    }
    app.run()
    exit(0)
}

private func captureWindow(_ window: NSWindow, to path: String) {
    let windowID = CGWindowID(window.windowNumber)
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                              [.bestResolution]) else {
        print("capture failed for \(path)")
        return
    }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        print("could not create \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("captured \(path)")
}

// Headless pipeline check: riffle --selftest <wav file>
// Exercises the same code paths the app uses: whisper-server supervision,
// transcription, LLM cleanup, and the output guardrails.
func runSelfTest(wavPath: String) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        code = await selfTest(wavPath: wavPath)
        semaphore.signal()
    }
    semaphore.wait()
    return code
}

private func selfTest(wavPath: String) async -> Int32 {
    print("riffle selftest")
    let config = RiffleConfig.load()
    let whisper = WhisperService(config: config)
    print("whisper binary: \(config.resolvedWhisperBinary)")
    print("whisper model:  \(config.resolvedWhisperModel)")
    guard whisper.binaryExists else {
        print("FAIL: whisper-server binary missing")
        return 1
    }
    guard whisper.modelExists else {
        print("FAIL: whisper model missing")
        return 1
    }

    whisper.startIfNeeded()
    var up = false
    for _ in 0..<120 {
        if await whisper.isHealthy() { up = true; break }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    guard up else {
        print("FAIL: whisper-server did not come up, see whisper-server.log")
        whisper.shutdown()
        return 1
    }
    print("whisper-server: up on port \(config.whisperPort)")

    let t0 = Date()
    var raw: String
    do {
        raw = try await whisper.transcribe(wavURL: URL(fileURLWithPath: wavPath))
    } catch {
        print("FAIL: transcription: \(error.localizedDescription)")
        whisper.shutdown()
        return 1
    }
    let whisperMs = Int(Date().timeIntervalSince(t0) * 1000)
    raw = TextCleanup.sanitizeWhisper(raw)
    print("raw (\(whisperMs) ms): \(raw)")
    guard !raw.isEmpty else {
        print("FAIL: empty transcript")
        whisper.shutdown()
        return 1
    }

    let ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
    guard await ollama.isUp() else {
        print("WARN: ollama not reachable, cleanup untested")
        whisper.shutdown()
        return 0
    }
    guard await ollama.hasModel() else {
        print("WARN: model \(config.llmModel) missing, run: ollama pull \(config.llmModel)")
        whisper.shutdown()
        return 0
    }

    let t1 = Date()
    do {
        let cleaned = try await ollama.cleanup(transcript: raw, appName: "Messages",
                                               dictionary: config.dictionary)
        let cleanupMs = Int(Date().timeIntervalSince(t1) * 1000)
        let result = TextCleanup.guardrail(raw: TextCleanup.basicTidy(raw), cleaned: cleaned)
        print("cleaned (\(cleanupMs) ms, llm=\(result.1)): \(result.0)")
    } catch {
        print("FAIL: cleanup: \(error.localizedDescription)")
        whisper.shutdown()
        return 1
    }

    whisper.shutdown()
    print("selftest OK")
    return 0
}

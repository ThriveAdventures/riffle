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

// Headless Apple engine check: riffle --appletest "raw transcript"
func runAppleTest(raw: String) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        defer { semaphore.signal() }
        print("foundation models: \(AppleCleaner.availabilityDescription)")
        guard AppleCleaner.isAvailable else { return }
        let config = RiffleConfig.load()
        do {
            let t0 = Date()
            let cleaned = try await AppleCleaner.cleanup(transcript: raw, appName: "Messages",
                                                         dictionary: config.dictionary)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("raw model output: \(cleaned)")
            let result = TextCleanup.guardrail(raw: TextCleanup.basicTidy(raw), cleaned: cleaned)
            print("after guardrail (\(ms) ms, llm=\(result.1)): \(result.0)")
            code = 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
        }
    }
    semaphore.wait()
    return code
}

// Regenerate a meeting summary from an existing notes file:
// riffle --summarizetest <notes.md>
func runSummarizeTest(path: String, context: String?) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task {
        defer { semaphore.signal() }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("FAIL: cannot read \(path)")
            return
        }
        var mic: [WhisperService.Segment] = []
        var system: [WhisperService.Segment] = []
        let regex = try! NSRegularExpression(pattern: "^- \\[(\\d+):(\\d+)\\] (You|Them): (.*)$")
        for line in content.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range),
                  let mm = Range(m.range(at: 1), in: line).map({ Double(line[$0]) ?? 0 }),
                  let ss = Range(m.range(at: 2), in: line).map({ Double(line[$0]) ?? 0 }),
                  let sp = Range(m.range(at: 3), in: line).map({ String(line[$0]) }),
                  let tx = Range(m.range(at: 4), in: line).map({ String(line[$0]) })
            else { continue }
            let seg = WhisperService.Segment(start: mm * 60 + ss, end: mm * 60 + ss + 1, text: tx)
            if sp == "You" { mic.append(seg) } else { system.append(seg) }
        }
        guard !mic.isEmpty || !system.isEmpty else {
            print("FAIL: no transcript lines found")
            return
        }
        let transcript = MeetingNotes.mergedTranscript(mic: mic, system: system)
        let language = MeetingNotes.dominantLanguageName(transcript)
        print("segments: you=\(mic.count) them=\(system.count), merged turns=\(transcript.components(separatedBy: "\n").count), chars=\(transcript.count), language=\(language)")
        let config = RiffleConfig.load()
        let ollama = OllamaClient(baseURL: config.ollamaUrl, model: config.llmModel)
        ollama.summaryModel = config.summaryModel.isEmpty ? nil : config.summaryModel
        guard await ollama.isUp(), await ollama.hasModel() else {
            print("FAIL: ollama unavailable")
            return
        }
        do {
            let summary = try await ollama.summarizeMeeting(transcript: transcript, minutes: 45,
                                                            language: language, context: context)
            let md = MeetingNotes.build(transcript: transcript, seconds: 2671, summary: summary)
            let out = path.replacingOccurrences(of: ".md", with: "-v2.md")
            try md.data(using: .utf8)?.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
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

func runHudTest(capturePrefix: String?, framesDir: String? = nil) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let hud = HUD()
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/Riffle.app")
    hud.showListening(handsFree: false, appIcon: icon, prime: true)
    var t: Double = 0
    var frame = 0
    if let framesDir {
        try? FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
    }
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        t += 0.05
        if let framesDir, Int(round(t * 20)) % 2 == 0 {
            frame += 1
            captureWindow(hud.testWindow, to: String(format: "%@/frame-%03d.png", framesDir, frame))
        }
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

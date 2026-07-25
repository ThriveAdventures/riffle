import Foundation

// Supervises a local whisper-server child process and talks to it over HTTP.
// The server keeps the model in memory, so per-dictation latency stays low.
final class WhisperService {

    private let binaryPath: String
    private let modelPath: String
    private let port: Int
    private let language: String
    private let prompt: String

    private var process: Process?
    private var restarts = 0
    private var shuttingDown = false
    private(set) var lastError: String?

    init(config: RiffleConfig) {
        binaryPath = config.resolvedWhisperBinary
        modelPath = config.resolvedWhisperModel
        port = config.whisperPort
        language = config.language
        prompt = config.dictionary.joined(separator: ", ")
    }

    var modelExists: Bool { FileManager.default.fileExists(atPath: modelPath) }
    var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binaryPath) }
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func startIfNeeded() {
        guard !shuttingDown else { return }
        if let process, process.isRunning { return }
        spawn()
    }

    private func spawn() {
        guard binaryExists else {
            lastError = "whisper-server not found at \(binaryPath)"
            Log.write("whisper: \(lastError ?? "")")
            return
        }
        guard modelExists else {
            lastError = "model not found at \(modelPath)"
            Log.write("whisper: \(lastError ?? "")")
            return
        }

        // Reap any orphaned server from a previous crash or kill; it holds
        // both the port and about 1.7 GB of memory.
        let reap = Process()
        reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reap.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? reap.run()
        reap.waitUntilExit()
        usleep(150_000)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 6)
        var args = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-t", String(threads),
            "-l", language,
            "-sns",
        ]
        if !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        p.arguments = args

        let serverLog = RiffleConfig.dir.appendingPathComponent("whisper-server.log").path
        if !FileManager.default.fileExists(atPath: serverLog) {
            FileManager.default.createFile(atPath: serverLog, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: serverLog) {
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown else { return }
                self.process = nil
                self.restarts += 1
                self.lastError = "whisper-server exited with code \(proc.terminationStatus)"
                Log.write("whisper: exited code \(proc.terminationStatus), restart attempt \(self.restarts)")
                guard self.restarts <= 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + min(Double(self.restarts) * 2.0, 15)) {
                    self.startIfNeeded()
                }
            }
        }

        do {
            try p.run()
            process = p
            lastError = nil
            Log.write("whisper: started pid \(p.processIdentifier), port \(port), threads \(threads), language \(language)")
        } catch {
            lastError = "failed to launch whisper-server: \(error.localizedDescription)"
            Log.write("whisper: \(lastError ?? "")")
        }
    }

    func shutdown() {
        shuttingDown = true
        process?.terminate()
        process = nil
    }

    func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 2
        do {
            _ = try await URLSession.shared.data(for: req)
            return true
        } catch {
            return false
        }
    }

    func transcribe(wavURL: URL) async throws -> String {
        let boundary = "riffle-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("temperature", "0.0")
        field("temperature_inc", "0.2")
        field("response_format", "json")
        let fileData = try Data(contentsOf: wavURL)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Riffle", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "whisper-server returned HTTP \(code)"])
        }

        struct InferenceResponse: Decodable {
            let text: String?
            let error: String?
        }
        let r = try JSONDecoder().decode(InferenceResponse.self, from: data)
        if let e = r.error, !e.isEmpty {
            throw NSError(domain: "Riffle", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "whisper-server error: \(e)"])
        }
        restarts = 0
        return (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

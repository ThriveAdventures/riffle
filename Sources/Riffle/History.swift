import Foundation

// Local dictation history, one JSON object per line. Never leaves this Mac.
enum History {
    static var url: URL { RiffleConfig.dir.appendingPathComponent("history.jsonl") }

    static func append(raw: String, cleaned: String, app: String?,
                       seconds: Double, transcribeMs: Int, cleanupMs: Int) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "app": app ?? "",
            "seconds": (seconds * 10).rounded() / 10,
            "raw": raw,
            "text": cleaned,
            "whisper_ms": transcribeMs,
            "cleanup_ms": cleanupMs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        var line = data
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: RiffleConfig.dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

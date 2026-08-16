import Foundation

// Local dictation history, one JSON object per line. Never leaves this Mac.
enum History {
    static var url: URL { RiffleConfig.dir.appendingPathComponent("history.jsonl") }

    static func append(raw: String, cleaned: String, app: String?,
                       seconds: Double, transcribeMs: Int, cleanupMs: Int,
                       edit: Bool = false) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "app": app ?? "",
            "seconds": (seconds * 10).rounded() / 10,
            "raw": raw,
            "text": cleaned,
            "whisper_ms": transcribeMs,
            "cleanup_ms": cleanupMs,
            "edit": edit,
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

    struct Entry {
        let date: Date
        let text: String
        let app: String

        // "18:55  Claude  858 chars" plus the opening words, enough to
        // recognize a dictation without opening the file.
        var menuLabel: String {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let preview = flat.count > 48 ? String(flat.prefix(48)) + "..." : flat
            return "\(clock.string(from: date))  \(text.count) chars  \(preview)"
        }
    }

    // Most recent dictations, newest first. Reads the tail of the file only,
    // so a long history does not slow down opening the menu.
    static func recent(limit: Int = 10) -> [Entry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let parser = ISO8601DateFormatter()
        var out: [Entry] = []
        for line in content.split(separator: "\n").reversed() {
            guard out.count < limit,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty,
                  obj["edit"] as? Bool != true
            else { continue }
            let date = (obj["ts"] as? String).flatMap { parser.date(from: $0) } ?? Date()
            out.append(Entry(date: date, text: text, app: obj["app"] as? String ?? ""))
        }
        return out
    }
}

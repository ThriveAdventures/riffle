import Foundation

// Builds and saves the meeting notes markdown: summary on top, attributed
// timestamped transcript below. Everything stays local.
enum MeetingNotes {

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Meetings")
    }

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func mergedTranscript(mic: [WhisperService.Segment],
                                 system: [WhisperService.Segment]) -> String {
        struct Line { let start: Double; let speaker: String; let text: String }
        var lines: [Line] = []
        lines += mic.map { Line(start: $0.start, speaker: "You", text: $0.text) }
        lines += system.map { Line(start: $0.start, speaker: "Them", text: $0.text) }
        lines.sort { $0.start < $1.start }
        return lines.map { "- [\(mmss($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    static func build(transcript: String, seconds: Double, summary: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# Meeting notes, \(df.string(from: Date()))\n\n"
        md += "Duration: \(Int(seconds / 60)) min \(Int(seconds) % 60) s. "
        md += "Recorded and summarized locally by Riffle.\n\n"
        if let summary, !summary.isEmpty {
            md += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        } else {
            md += "Summary unavailable (local model offline); transcript below.\n\n"
        }
        md += "## Transcript\n\n" + transcript + "\n"
        return md
    }

    static func save(_ markdown: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        var url = dir.appendingPathComponent("\(df.string(from: Date())).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(df.string(from: Date()))-\(n).md")
            n += 1
        }
        try markdown.data(using: .utf8)?.write(to: url)
        return url
    }
}

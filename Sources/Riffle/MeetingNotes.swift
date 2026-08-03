import Foundation
import NaturalLanguage

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
        // Filter whisper's silence hallucinations from the mic track: the
        // classic phrases it invents on near-silent audio, when repeated.
        let hallucinations: Set<String> = [
            "thank you.", "thank you", "thanks for watching.", "merci.",
            "sous-titrage société radio-canada",
            "sous-titres réalisés para la communauté d'amara.org",
        ]
        var counts: [String: Int] = [:]
        for seg in mic { counts[seg.text.lowercased(), default: 0] += 1 }
        let filteredMic = mic.filter { seg in
            let key = seg.text.lowercased()
            return !(hallucinations.contains(key) && counts[key, default: 0] >= 2)
        }

        var lines: [Line] = []
        lines += filteredMic.map { Line(start: $0.start, speaker: "You", text: $0.text) }
        lines += system.map { Line(start: $0.start, speaker: "Them", text: $0.text) }
        lines.sort { $0.start < $1.start }

        // Merge consecutive same-speaker segments into turns: whisper cuts
        // every few seconds, and one line per snippet triples the token
        // count and buries the conversation shape.
        struct Turn { let start: Double; let speaker: String; var text: String }
        var turns: [Turn] = []
        for line in lines {
            if var last = turns.last, last.speaker == line.speaker {
                last.text += " " + line.text
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(start: line.start, speaker: line.speaker, text: line.text))
            }
        }
        return turns.map { "- [\(mmss($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    // Human-readable dominant language, used to force the summary into the
    // meeting's own language.
    static func dominantLanguageName(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(8000)))
        guard let lang = recognizer.dominantLanguage else { return "the transcript's language" }
        return Locale(identifier: "en").localizedString(forIdentifier: lang.rawValue)
            ?? "the transcript's language"
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

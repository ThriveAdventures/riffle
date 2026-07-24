import Foundation

enum TextCleanup {

    // Whisper annotates non-speech as [Music], [BLANK_AUDIO], (bell dings),
    // and so on. Strip bracketed noise. If nothing but noise remains, the
    // clip had no speech.
    static func sanitizeWhisper(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withoutNoise = trimmed
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutNoise.isEmpty { return "" }
        // Whisper wraps output in arbitrary segment line breaks, often mid
        // sentence. Real paragraph breaks come from the spoken words "new
        // paragraph", so flattening these is safe and keeps the LLM sane.
        return trimmed
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Minimal cleanup used when the LLM pass is off or unavailable.
    static func basicTidy(_ text: String) -> String {
        var t = text
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first.isLowercase {
            t = first.uppercased() + t.dropFirst()
        }
        return t
    }

    // Sanity checks on LLM output. If the model went off the rails, fall
    // back to the raw transcript. Returns the text and whether the LLM
    // version was used.
    static func guardrail(raw: String, cleaned: String) -> (String, Bool) {
        var c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return (raw, false) }

        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] {
            if c.hasPrefix(open), c.hasSuffix(close), c.count > 2, !raw.hasPrefix(open) {
                c = String(c.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !c.isEmpty else { return (raw, false) }

        let lower = c.lowercased()
        let rawLower = raw.lowercased()
        for marker in ["as an ai", "i cannot help", "i can't help",
                       "here is the cleaned", "here's the cleaned"] {
            if lower.contains(marker), !rawLower.contains(marker) { return (raw, false) }
        }

        if raw.count >= 60 {
            let ratio = Double(c.count) / Double(raw.count)
            if ratio < 0.3 || ratio > 2.6 { return (raw, false) }
        }

        c = c.replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
        return (c, true)
    }
}

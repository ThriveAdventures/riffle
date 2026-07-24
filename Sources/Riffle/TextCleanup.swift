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

    // Deterministic find-and-replace rules from config, applied after the
    // LLM pass. Case-insensitive, whole-word where the term edges are
    // alphanumeric.
    static func applyReplacements(_ text: String, rules: [RiffleConfig.Replacement]) -> String {
        var t = text
        for rule in rules {
            let find = rule.find.trimmingCharacters(in: .whitespaces)
            guard !find.isEmpty else { continue }
            var pattern = NSRegularExpression.escapedPattern(for: find)
            if let first = find.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) {
                pattern = "\\b" + pattern
            }
            if let last = find.unicodeScalars.last, CharacterSet.alphanumerics.contains(last) {
                pattern += "\\b"
            }
            let template = rule.replace
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            t = t.replacingOccurrences(of: "(?i)" + pattern, with: template,
                                       options: .regularExpression)
        }
        return t
    }

    // Sanity checks for edit-mode output. Returns nil when the result looks
    // unsafe to paste over the user's selection; the caller then leaves the
    // selection untouched.
    static func guardrailEdit(output: String) -> String? {
        var c = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] {
            if c.hasPrefix(open), c.hasSuffix(close), c.count > 2 {
                c = String(c.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !c.isEmpty else { return nil }
        let lower = c.lowercased()
        for marker in ["as an ai", "i cannot help", "i can't help"] {
            if lower.contains(marker) { return nil }
        }
        for prefix in ["here is", "here's", "sure,", "sure."] {
            if lower.hasPrefix(prefix) { return nil }
        }
        c = c.replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
        return c
    }
}

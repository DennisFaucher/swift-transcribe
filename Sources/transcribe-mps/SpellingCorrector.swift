import Foundation

/// Applies a user-supplied list of whole-word replacements to transcribed
/// text, e.g. to fix consistent Whisper mis-hearings of proper nouns
/// ("Sincora" -> "Cencora").
struct SpellingCorrector {
    private struct Rule {
        let pattern: NSRegularExpression
        let replacement: String
    }

    private let rules: [Rule]

    var count: Int { rules.count }

    /// Loads a two-column list from `path`: one misspelling/correction pair
    /// per line, columns separated by a tab or comma (whitespace-trimmed).
    /// Blank lines and lines starting with '#' are ignored. Returns nil if
    /// the file can't be read or contains no usable rules.
    static func load(path: String) -> SpellingCorrector? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var rules: [Rule] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let columns: [String]
            if line.contains("\t") {
                columns = line.components(separatedBy: "\t")
            } else if line.contains(",") {
                columns = line.components(separatedBy: ",")
            } else {
                columns = line.split(separator: " ", maxSplits: 1).map(String.init)
            }
            guard columns.count >= 2 else { continue }
            let misspelled = unquoted(columns[0].trimmingCharacters(in: .whitespaces))
            let correct = unquoted(columns[1].trimmingCharacters(in: .whitespaces))
            guard !misspelled.isEmpty, !correct.isEmpty else { continue }

            // A multi-word misspelling ("Brick Osh") is matched as a phrase:
            // word boundaries around the whole thing, any single run of
            // whitespace between its words matching any run in the text.
            let escapedWords = misspelled.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "\\b" + escapedWords.joined(separator: "\\s+") + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            rules.append(Rule(pattern: regex, replacement: correct))
        }
        guard !rules.isEmpty else { return nil }
        return SpellingCorrector(rules: rules)
    }

    /// Strips one layer of surrounding matching quotes, if present - quoting
    /// a multi-word entry (e.g. "Brick Osh") is optional but tolerated.
    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last, first == last,
              first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    func apply(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.pattern.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement))
        }
        return result
    }
}

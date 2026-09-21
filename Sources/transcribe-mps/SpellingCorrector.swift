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
            let misspelled = columns[0].trimmingCharacters(in: .whitespaces)
            let correct = columns[1].trimmingCharacters(in: .whitespaces)
            guard !misspelled.isEmpty, !correct.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: misspelled)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else { continue }
            rules.append(Rule(pattern: regex, replacement: correct))
        }
        guard !rules.isEmpty else { return nil }
        return SpellingCorrector(rules: rules)
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

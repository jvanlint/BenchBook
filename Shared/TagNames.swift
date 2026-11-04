import Foundation

/// Tag text rules shared by every place tags are entered.
nonisolated enum TagNames {
    /// Splits "wheel well, Cockpit ,  decals" into display names,
    /// dropping blanks and case-insensitive duplicates.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(separator: ",")
            .map { collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty && seen.insert(normalize($0)).inserted }
    }

    static func normalize(_ name: String) -> String {
        collapseWhitespace(name).lowercased()
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

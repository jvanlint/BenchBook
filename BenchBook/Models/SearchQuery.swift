import Foundation

/// A piece of text prepared for searching: folded to ignore case, accents
/// and full-width forms, plus a compact form without spaces or punctuation
/// so "f16" finds "F-16" and "36270" finds "FS 36270".
nonisolated struct SearchField: Sendable {
    let text: String
    let folded: String
    let compact: String

    init(_ text: String) {
        self.text = text
        folded = SearchField.fold(text)
        compact = SearchField.compact(folded)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func compact(_ folded: String) -> String {
        String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}

/// A tag chosen as a token in the search field.
struct SearchTagToken: Identifiable, Hashable {
    let normalizedName: String
    let name: String
    var id: String { normalizedName }
}

/// What the user typed, split into words, plus any tag tokens. An item
/// matches when every word is found in it and it has every tag.
nonisolated struct SearchQuery: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        let text: String
        let folded: String
        let compact: String
    }

    let words: [Word]
    /// Normalized tag names, as `TagNames.normalize` makes them.
    let tags: Set<String>

    init(text: String, tags: Set<String> = []) {
        words = text.split(whereSeparator: \.isWhitespace).map { piece in
            let folded = SearchField.fold(String(piece))
            return Word(text: String(piece), folded: folded, compact: SearchField.compact(folded))
        }
        self.tags = tags
    }

    var isEmpty: Bool { words.isEmpty && tags.isEmpty }

    func word(_ word: Word, matches field: SearchField) -> Bool {
        if field.folded.contains(word.folded) { return true }
        // Otherwise compare without spaces and punctuation: "xf54" finds "XF-54".
        return !word.compact.isEmpty && field.compact.contains(word.compact)
    }

    /// True when `field` contains at least one of the words.
    func matchesAnyWord(_ field: SearchField) -> Bool {
        words.contains { word($0, matches: field) }
    }

    /// True when every word is in at least one of `fields`.
    func matchesEveryWord(in fields: [SearchField]) -> Bool {
        words.allSatisfy { word in fields.contains { self.word(word, matches: $0) } }
    }
}

/// A short excerpt of `text` around the first match, with matches marked.
nonisolated enum SearchSnippet {
    static func excerpt(of text: String, for query: SearchQuery, radius: Int = 60) -> AttributedString {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let first = query.words.compactMap { flat.range(of: $0.text, options: options) }
            .min { $0.lowerBound < $1.lowerBound }

        var start = flat.startIndex
        var prefix = ""
        if let first, flat.distance(from: flat.startIndex, to: first.lowerBound) > radius {
            start = flat.index(first.lowerBound, offsetBy: -radius / 2)
            // Begin at a word boundary.
            if let space = flat[start...].firstIndex(of: " "), space < first.lowerBound {
                start = flat.index(after: space)
            }
            prefix = "…"
        }
        let end = flat.index(start, offsetBy: radius * 2, limitedBy: flat.endIndex) ?? flat.endIndex
        let suffix = end < flat.endIndex ? "…" : ""
        return highlighted(prefix + flat[start..<end] + suffix, for: query)
    }

    /// `text` with every occurrence of the query's words in bold.
    static func highlighted(_ text: String, for query: SearchQuery) -> AttributedString {
        var result = AttributedString(text)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        for word in query.words where !word.text.isEmpty {
            var searchStart = text.startIndex
            while let range = text.range(of: word.text, options: options, range: searchStart..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

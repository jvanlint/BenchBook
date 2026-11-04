import Foundation

/// Stored as `Reference.kindRaw`.
nonisolated enum ReferenceKind: String, CaseIterable, Codable, Sendable {
    case image
    case pdf
    case markdown
    case webpage
    case videoLink
    case textSnippet
    /// Text the user wrote in BenchBook, rather than captured.
    case note

    /// Kinds whose original bytes are kept in the asset library.
    var storesFile: Bool {
        switch self {
        case .image, .pdf, .markdown: true
        case .webpage, .videoLink, .textSnippet, .note: false
        }
    }

    var displayName: String {
        switch self {
        case .image: String(localized: "Image")
        case .pdf: String(localized: "PDF")
        case .markdown: String(localized: "Markdown")
        case .webpage: String(localized: "Webpage")
        case .videoLink: String(localized: "Video")
        case .textSnippet: String(localized: "Text")
        case .note: String(localized: "Note")
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .markdown: "doc.plaintext"
        case .webpage: "globe"
        case .videoLink: "play.rectangle"
        case .textSnippet: "text.quote"
        case .note: "note.text"
        }
    }
}

extension Reference {
    /// Nil if the store holds a kind this version doesn't know about.
    var kind: ReferenceKind? {
        ReferenceKind(rawValue: kindRaw)
    }

    /// Tags sorted by name, for display.
    var tags: [Tag] {
        tagLinks
            .compactMap(\.tag)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var sortedVideoMoments: [VideoMoment] {
        videoMoments.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }

    /// The best short label: title, file name, text excerpt or host.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let filename = asset?.originalFilename, !filename.isEmpty { return filename }
        if let text, !text.isEmpty {
            return String(text.split(whereSeparator: \.isNewline).first ?? "").prefix(120).description
        }
        if let host = sourcePageURL?.host() { return host }
        return kind?.displayName ?? String(localized: "Reference")
    }
}

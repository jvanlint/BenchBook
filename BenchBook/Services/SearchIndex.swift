import Foundation
import Observation
import SwiftData

/// Where in a Reference a search matched.
enum SearchMatchKind: Equatable {
    case title, fileName, type, tag, link, text, note, channel, site, description
    /// The text of a box drawn on an image.
    case imageNote(id: UUID, number: Int)
    /// The text of a note, highlight or arrow on a PDF.
    case markup(id: UUID, number: Int, kind: MarkupKind)
    /// A named point in a video.
    case moment(seconds: Double)

    /// Shown before the excerpt, e.g. "Box 2" or "Description".
    var label: String {
        switch self {
        case .title: String(localized: "Title")
        case .fileName: String(localized: "File Name")
        case .type: String(localized: "Type")
        case .tag: String(localized: "Tag")
        case .link: String(localized: "Link")
        case .text: String(localized: "Text")
        case .note: String(localized: "Note")
        case .channel: String(localized: "Channel")
        case .site: String(localized: "Site")
        case .description: String(localized: "Description")
        case .imageNote(_, let number): String(localized: "Box \(number)")
        case .markup(_, let number, let kind): "\(kind.displayName) \(number)"
        case .moment(let seconds): VideoLink.format(seconds: seconds)
        }
    }

    /// Matches that need their own line in results; the rest show in the row itself.
    var isShownAsLine: Bool {
        switch self {
        case .title, .type, .tag: false
        default: true
        }
    }
}

struct SearchMatch {
    let kind: SearchMatchKind
    let text: String
}

struct ReferenceSearchHit: Identifiable {
    let reference: Reference
    /// Every part that contains a searched word, in reading order.
    let matches: [SearchMatch]
    var id: UUID { reference.id }
}

struct ProjectSearchGroup: Identifiable {
    let project: Project
    let hits: [ReferenceSearchHit]
    var id: UUID { project.id }
}

struct SearchResults {
    var projects: [Project] = []
    var paints: [Paint] = []
    var aftermarketItems: [AftermarketItem] = []
    var referenceGroups: [ProjectSearchGroup] = []

    var referenceCount: Int { referenceGroups.reduce(0) { $0 + $1.hits.count } }
    var isEmpty: Bool { projects.isEmpty && paints.isEmpty && aftermarketItems.isEmpty && referenceGroups.isEmpty }
}

/// Searches every Project, Paint and Reference, including the notes drawn
/// on images and PDFs. The searchable text is prepared once and rebuilt after the
/// library is saved, so typing stays fast.
@Observable
final class SearchIndex {
    /// Changes whenever the library is saved, so open results refresh.
    private(set) var generation = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var isStale = true
    @ObservationIgnored private var projectEntries: [(project: Project, fields: [SearchField])] = []
    @ObservationIgnored private var paintEntries: [(paint: Paint, fields: [SearchField])] = []
    @ObservationIgnored private var aftermarketEntries: [(item: AftermarketItem, fields: [SearchField])] = []
    @ObservationIgnored private var referenceEntries: [ReferenceEntry] = []
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private struct Part {
        let kind: SearchMatchKind
        let field: SearchField
    }

    private struct ReferenceEntry {
        let reference: Reference
        let projectID: UUID?
        let tags: Set<String>
        let parts: [Part]
    }

    init(context: ModelContext) {
        self.context = context
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markStale() }
        }
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    func markStale() {
        isStale = true
        generation += 1
    }

    func search(_ query: SearchQuery) -> SearchResults {
        guard !query.isEmpty else { return SearchResults() }
        rebuildIfNeeded()
        var results = SearchResults()

        // Only References have tags, so a tag token leaves only References.
        if query.tags.isEmpty {
            results.projects = projectEntries
                .filter { query.matchesEveryWord(in: $0.fields) }
                .map(\.project)
            results.paints = paintEntries
                .filter { query.matchesEveryWord(in: $0.fields) }
                .map(\.paint)
            results.aftermarketItems = aftermarketEntries
                .filter { query.matchesEveryWord(in: $0.fields) }
                .map(\.item)
        }

        var hitsByProject: [UUID: [ReferenceSearchHit]] = [:]
        for entry in referenceEntries {
            guard let projectID = entry.projectID,
                  query.tags.isSubset(of: entry.tags),
                  query.matchesEveryWord(in: entry.parts.map(\.field))
            else { continue }
            let matches = entry.parts
                .filter { query.matchesAnyWord($0.field) }
                .map { SearchMatch(kind: $0.kind, text: $0.field.text) }
            hitsByProject[projectID, default: []].append(ReferenceSearchHit(reference: entry.reference, matches: matches))
        }
        results.referenceGroups = projectEntries.compactMap { entry in
            guard let hits = hitsByProject[entry.project.id] else { return nil }
            // Title matches first, then newest first, as in the gallery.
            let sorted = hits.sorted { lhs, rhs in
                let lhsTitle = lhs.matches.contains { $0.kind == .title }
                let rhsTitle = rhs.matches.contains { $0.kind == .title }
                if lhsTitle != rhsTitle { return lhsTitle }
                return lhs.reference.capturedAt > rhs.reference.capturedAt
            }
            return ProjectSearchGroup(project: entry.project, hits: sorted)
        }
        return results
    }

    // MARK: Building

    private func rebuildIfNeeded() {
        guard isStale else { return }
        isStale = false

        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        projectEntries = projects
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { project in
                let texts = [project.name, project.manufacturer, project.subject, project.scale,
                             project.kitNumber ?? "", project.markingsScheme ?? "", project.notes ?? ""]
                return (project, texts.filter { !$0.isEmpty }.map(SearchField.init))
            }

        let paints = (try? context.fetch(FetchDescriptor<Paint>())) ?? []
        paintEntries = paints
            .sorted { lhs, rhs in
                let brand = lhs.brand.localizedStandardCompare(rhs.brand)
                if brand != .orderedSame { return brand == .orderedAscending }
                return lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
            }
            .map { paint in
                let texts = [paint.brand, paint.range, paint.code, paint.name, paint.standardCode, paint.notes ?? ""]
                return (paint, texts.filter { !$0.isEmpty }.map(SearchField.init))
            }

        let items = (try? context.fetch(FetchDescriptor<AftermarketItem>())) ?? []
        aftermarketEntries = items
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { item in
                let texts = [item.productName, item.manufacturer, item.productNumber ?? "", item.typeName,
                             item.scaleCompatibility ?? "", item.notes ?? "", item.productURL?.host() ?? ""]
                return (item, texts.filter { !$0.isEmpty }.map(SearchField.init))
            }

        let references = (try? context.fetch(FetchDescriptor<Reference>())) ?? []
        referenceEntries = references.map { reference in
            ReferenceEntry(
                reference: reference,
                projectID: reference.project?.id,
                tags: Set(reference.tags.map(\.normalizedName)),
                parts: Self.parts(of: reference)
            )
        }
    }

    private static func parts(of reference: Reference) -> [Part] {
        var parts: [Part] = []
        func add(_ kind: SearchMatchKind, _ text: String?) {
            if let text = text?.trimmedOrNil { parts.append(Part(kind: kind, field: SearchField(text))) }
        }
        add(.title, reference.displayTitle)
        add(.type, reference.kind?.displayName)
        for tag in reference.tags { add(.tag, tag.name) }
        if let filename = reference.asset?.originalFilename, filename != reference.displayTitle {
            add(.fileName, filename)
        }
        add(.link, reference.sourcePageURL?.absoluteString)
        add(.text, reference.text.flatMap { $0 == reference.displayTitle ? nil : $0 })
        add(.note, reference.note)
        add(.channel, reference.videoChannel)
        add(.site, reference.linkSiteName)
        add(.description, reference.videoDescription ?? reference.linkDescription)
        for (index, note) in reference.sortedImageNotes.enumerated() {
            add(.imageNote(id: note.id, number: index + 1), note.text)
        }
        for (index, markup) in (reference.kind == .image ? [] : reference.sortedMarkups).enumerated() {
            add(.markup(id: markup.id, number: index + 1, kind: markup.kind), markup.text)
        }
        for moment in reference.sortedVideoMoments {
            add(.moment(seconds: moment.offsetSeconds), [moment.title, moment.note].compactMap { $0 }.joined(separator: " — "))
        }
        return parts
    }
}

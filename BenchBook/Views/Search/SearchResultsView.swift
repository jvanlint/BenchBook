import QuickLook
import SwiftData
import SwiftUI

/// One row in the search results.
enum SearchResultID: Hashable {
    case project(UUID)
    case paint(UUID)
    case aftermarket(UUID)
    case reference(UUID)
    /// A box drawn on an image.
    case imageNote(reference: UUID, note: UUID)
    case moment(reference: UUID, seconds: Double)
}

/// Results for a search across every Project: projects, paints, aftermarket
/// parts, then
/// references grouped by project. Matching image boxes and video moments
/// get their own rows so they can be opened directly.
struct SearchResultsView: View {
    let query: SearchQuery
    var title: String = String(localized: "Search")
    var onShowProject: (Project) -> Void
    var onShowReference: (Reference) -> Void
    var onShowPaint: (Paint) -> Void
    var onShowAftermarketItem: (AftermarketItem) -> Void

    @Environment(\.searchIndex) private var searchIndex
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var selection: SearchResultID?
    @State private var quickLookURL: URL?
    @State private var detailsReference: Reference?
    @State private var paintEditor: PaintEditorRequest?
    @State private var aftermarketEditor: AftermarketEditorView.Request?
    @State private var errorMessage: String?

    var body: some View {
        // Reading the generation refreshes results after any save.
        let _ = searchIndex?.generation
        let results = searchIndex?.search(query) ?? SearchResults()

        Group {
            if results.isEmpty, query.words.isEmpty {
                ContentUnavailableView(
                    "No References",
                    systemImage: "tag",
                    description: Text("Nothing has this tag yet. Drag references onto it in the sidebar.")
                )
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query.words.map(\.text).joined(separator: " "))
            } else {
                list(results)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(summary(results))
        .quickLookPreview($quickLookURL)
        .sheet(item: $detailsReference) { reference in
            if reference.kind == .note {
                NoteEditorView(request: .edit(reference))
            } else {
                ReferenceDetailsView(reference: reference)
            }
        }
        .sheet(item: $paintEditor) { request in
            PaintEditorView(request: request)
        }
        .sheet(item: $aftermarketEditor) { request in
            NavigationStack { AftermarketEditorView(request: request) }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func list(_ results: SearchResults) -> some View {
        List(selection: $selection) {
            if !results.projects.isEmpty {
                Section("Projects") {
                    ForEach(results.projects) { project in
                        projectRow(project).tag(SearchResultID.project(project.id))
                    }
                }
            }
            if !results.paints.isEmpty {
                Section("Paints") {
                    ForEach(results.paints) { paint in
                        paintRow(paint).tag(SearchResultID.paint(paint.id))
                    }
                }
            }
            if !results.aftermarketItems.isEmpty {
                Section("Aftermarket") {
                    ForEach(results.aftermarketItems) { item in
                        aftermarketRow(item).tag(SearchResultID.aftermarket(item.id))
                    }
                }
            }
            ForEach(results.referenceGroups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        referenceRow(hit).tag(SearchResultID.reference(hit.reference.id))
                        ForEach(Array(hit.matches.enumerated()), id: \.offset) { _, match in
                            childRow(match, in: hit.reference)
                        }
                    }
                } header: {
                    Text("\(group.project.name) — \(group.hits.count) references")
                }
            }
        }
        .contextMenu(forSelectionType: SearchResultID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                menu(for: id, in: results)
            }
        } primaryAction: { ids in
            if let id = ids.first { activate(id, in: results) }
        }
    }

    // MARK: Rows

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer")
                .foregroundStyle(.secondary)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted(project.name, for: query))
                if !project.summary.isEmpty {
                    Text(project.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func paintRow(_ paint: Paint) -> some View {
        HStack(spacing: 10) {
            PaintSwatch(hex: paint.swatchHex, size: 20)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted(paint.displayName, for: query))
                let details = [paint.secondaryLine, paint.projectNames.joined(separator: ", ")].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(SearchSnippet.highlighted(details.joined(separator: " · "), for: query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(paint.isOwned ? "Owned" : "Not Owned")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func aftermarketRow(_ item: AftermarketItem) -> some View {
        HStack(spacing: 10) {
            AftermarketThumbnail(item: item, size: 32)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted(item.displayName, for: query))
                let details = [item.typeName, item.scaleCompatibility ?? "", item.project?.name ?? ""].filter { !$0.isEmpty }
                Text(SearchSnippet.highlighted(details.joined(separator: " · "), for: query))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(item.statusName, systemImage: item.status?.systemImage ?? "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func referenceRow(_ hit: ReferenceSearchHit) -> some View {
        let reference = hit.reference
        let lines = hit.matches.filter { match in
            switch match.kind {
            case .imageNote, .moment: false
            default: match.kind.isShownAsLine
            }
        }
        return HStack(alignment: .top, spacing: 10) {
            Color.clear
                .frame(width: 64, height: 48)
                .overlay { ReferencePreview(reference: reference, showsDuration: false, isCompact: true) }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted(reference.displayTitle, for: query))
                    .lineLimit(1)
                let tags = reference.tags.map(\.name).joined(separator: ", ")
                Label {
                    Text(SearchSnippet.highlighted(
                        [reference.kind?.displayName ?? "", tags].filter { !$0.isEmpty }.joined(separator: " · "),
                        for: query
                    ))
                } icon: {
                    Image(systemName: reference.kind?.systemImage ?? "questionmark.square")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Array(lines.prefix(2).enumerated()), id: \.offset) { _, match in
                    (Text("\(match.kind.label): ").foregroundStyle(.secondary)
                        + Text(SearchSnippet.excerpt(of: match.text, for: query)))
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// A matching box or moment, indented under its reference.
    @ViewBuilder
    private func childRow(_ match: SearchMatch, in reference: Reference) -> some View {
        switch match.kind {
        case .imageNote(let id, _):
            matchRow(match, systemImage: "rectangle.dashed")
                .tag(SearchResultID.imageNote(reference: reference.id, note: id))
                .help("Open the image at this box")
        case .moment(let seconds):
            matchRow(match, systemImage: "play.circle")
                .tag(SearchResultID.moment(reference: reference.id, seconds: seconds))
                .help("Open the video at \(VideoLink.format(seconds: seconds))")
        default:
            EmptyView()
        }
    }

    private func matchRow(_ match: SearchMatch, systemImage: String) -> some View {
        Label {
            (Text("\(match.kind.label): ").foregroundStyle(.secondary)
                + Text(SearchSnippet.excerpt(of: match.text, for: query)))
                .lineLimit(2)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, 74)
    }

    // MARK: Actions

    @ViewBuilder
    private func menu(for id: SearchResultID, in results: SearchResults) -> some View {
        switch id {
        case .project(let projectID):
            if let project = results.projects.first(where: { $0.id == projectID }) {
                Button("Show Project") { onShowProject(project) }
            }
        case .paint(let paintID):
            if let paint = results.paints.first(where: { $0.id == paintID }) {
                Button("Edit Paint…") { paintEditor = .edit(paint) }
                Button("Show in Paints") { onShowPaint(paint) }
            }
        case .aftermarket(let itemID):
            if let item = results.aftermarketItems.first(where: { $0.id == itemID }) {
                Button("Edit Part…") { aftermarketEditor = .edit(item) }
                Button("Show in Project") { onShowAftermarketItem(item) }
            }
        case .reference(let referenceID), .imageNote(let referenceID, _), .moment(let referenceID, _):
            if let reference = reference(referenceID, in: results) {
                Button("Open") { activate(id, in: results) }
                Button("Show in Project") { onShowReference(reference) }
                Divider()
                Button(reference.kind == .note ? "Edit Note…" : "Edit Details…") { detailsReference = reference }
            }
        }
    }

    private func activate(_ id: SearchResultID, in results: SearchResults) {
        switch id {
        case .project(let projectID):
            if let project = results.projects.first(where: { $0.id == projectID }) { onShowProject(project) }
        case .paint(let paintID):
            if let paint = results.paints.first(where: { $0.id == paintID }) { paintEditor = .edit(paint) }
        case .aftermarket(let itemID):
            if let item = results.aftermarketItems.first(where: { $0.id == itemID }) { onShowAftermarketItem(item) }
        case .reference(let referenceID):
            if let reference = reference(referenceID, in: results) { open(reference) }
        case .imageNote(let referenceID, let noteID):
            ImageViewerRequests.shared.noteToShow[referenceID] = noteID
            openWindow(id: ImageViewerWindow.id, value: referenceID)
        case .moment(let referenceID, let seconds):
            if let source = reference(referenceID, in: results)?.sourcePageURL {
                openURL(VideoLink.playbackURL(for: source, at: seconds))
            }
        }
    }

    /// Opens a reference the same way the gallery does.
    private func open(_ reference: Reference) {
        switch reference.kind {
        case .image:
            openWindow(id: ImageViewerWindow.id, value: reference.id)
        case .pdf, .markdown:
            guard let asset = reference.asset else { return }
            let url = assetLibrary.url(forRelativePath: asset.originalRelativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                quickLookURL = url
            } else {
                errorMessage = String(localized: "The saved copy of “\(reference.displayTitle)” is missing from the library.")
            }
        case .webpage:
            if let url = reference.sourcePageURL { openURL(url) }
        case .videoLink:
            guard let url = reference.sourcePageURL else { return }
            if let first = reference.sortedVideoMoments.first {
                openURL(VideoLink.playbackURL(for: url, at: first.offsetSeconds))
            } else {
                openURL(url)
            }
        case .textSnippet, .note, nil:
            detailsReference = reference
        }
    }

    private func reference(_ id: UUID, in results: SearchResults) -> Reference? {
        for group in results.referenceGroups {
            if let hit = group.hits.first(where: { $0.reference.id == id }) { return hit.reference }
        }
        return nil
    }

    private func summary(_ results: SearchResults) -> String {
        var parts: [String] = []
        if !results.projects.isEmpty { parts.append(String(localized: "\(results.projects.count) projects")) }
        if !results.paints.isEmpty { parts.append(String(localized: "\(results.paints.count) paints")) }
        if !results.aftermarketItems.isEmpty { parts.append(String(localized: "\(results.aftermarketItems.count) parts")) }
        if results.referenceCount > 0 { parts.append(String(localized: "\(results.referenceCount) references")) }
        return parts.joined(separator: " · ")
    }
}

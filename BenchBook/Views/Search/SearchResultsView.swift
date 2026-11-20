import QuickLook
import SwiftData
import SwiftUI

/// One row in the search results.
enum SearchResultID: Hashable {
    case project(UUID)
    case kit(UUID)
    case paint(UUID)
    case aftermarket(UUID)
    case reference(UUID)
    /// A box drawn on an image.
    case imageNote(reference: UUID, note: UUID)
    /// A note, highlight or arrow on a PDF.
    case markup(reference: UUID, markup: UUID)
    case moment(reference: UUID, seconds: Double)
    case buildPhoto(UUID)
    /// A box drawn on a build photo.
    case buildPhotoNote(photo: UUID, note: UUID)
}

/// Results for a search across every Project: projects, kits, paints,
/// aftermarket parts, then
/// references grouped by project. Matching image boxes and video moments
/// get their own rows so they can be opened directly.
struct SearchResultsView: View {
    let query: SearchQuery
    var title: String = String(localized: "Search")
    var onShowProject: (Project) -> Void
    var onShowReference: (Reference) -> Void
    var onShowKit: (Kit) -> Void
    var onShowPaint: (Paint) -> Void
    var onShowAftermarketItem: (AftermarketItem) -> Void
    var onShowBuildPhoto: (BuildPhoto) -> Void

    @Environment(\.searchIndex) private var searchIndex
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var selection: SearchResultID?
    @State private var quickLookURL: URL?
    @State private var detailsReference: Reference?
    @State private var kitEditor: KitEditorView.Request?
    @State private var paintEditor: PaintEditorRequest?
    @State private var aftermarketEditor: AftermarketEditorView.Request?
    @State private var detailsPhoto: BuildPhoto?
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
                    description: Text("Nothing has this tag yet. Drag references or build photos onto it in the sidebar.")
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
        .sheet(item: $kitEditor) { request in
            NavigationStack { KitEditorView(request: request) }
        }
        .sheet(item: $paintEditor) { request in
            PaintEditorView(request: request)
        }
        .sheet(item: $aftermarketEditor) { request in
            NavigationStack { AftermarketEditorView(request: request) }
        }
        .sheet(item: $detailsPhoto) { photo in
            BuildPhotoDetailsView(photo: photo)
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
            if !results.kits.isEmpty {
                Section("Kits") {
                    ForEach(results.kits) { kit in
                        kitRow(kit).tag(SearchResultID.kit(kit.id))
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
                    ForEach(group.photoHits) { hit in
                        photoRow(hit).tag(SearchResultID.buildPhoto(hit.photo.id))
                        ForEach(Array(hit.matches.enumerated()), id: \.offset) { _, match in
                            if case .imageNote(let noteID, _) = match.kind {
                                matchRow(match, systemImage: "rectangle.dashed")
                                    .tag(SearchResultID.buildPhotoNote(photo: hit.photo.id, note: noteID))
                                    .help("Open the photo at this box")
                            }
                        }
                    }
                } header: {
                    Text("\(group.project.name) — \(Self.groupSummary(group))")
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

    private func kitRow(_ kit: Kit) -> some View {
        HStack(spacing: 10) {
            KitThumbnail(kit: kit, size: 28)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted("\(kit.brand) \(kit.name)", for: query))
                let details = [kit.scale ?? "", kit.number ?? "", kit.notes ?? ""].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(SearchSnippet.highlighted(details.joined(separator: " · "), for: query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(kit.isOwned ? kit.status.displayName : String(localized: "Not Owned"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func paintRow(_ paint: Paint) -> some View {
        HStack(spacing: 10) {
            PaintSwatch(hex: paint.swatchHex, isClear: paint.isClear, size: 20)
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
            case .imageNote, .markup, .moment: false
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

    private func photoRow(_ hit: BuildPhotoSearchHit) -> some View {
        let photo = hit.photo
        let lines = hit.matches.filter { match in
            if case .imageNote = match.kind { return false }
            return match.kind.isShownAsLine
        }
        return HStack(alignment: .top, spacing: 10) {
            BuildPhotoThumbnail(photo: photo)
                .frame(width: 64, height: 48)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchSnippet.highlighted(photo.displayTitle, for: query))
                    .lineLimit(1)
                let tags = photo.tags.map(\.name).joined(separator: ", ")
                Label {
                    Text(SearchSnippet.highlighted(
                        [String(localized: "Build Photo"), photo.stage.displayName, tags].filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        for: query
                    ))
                } icon: {
                    Image(systemName: "camera")
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

    /// e.g. "3 references, 2 build photos".
    private static func groupSummary(_ group: ProjectSearchGroup) -> String {
        [
            group.hits.isEmpty ? nil : String(AttributedString(
                localized: "^[\(group.hits.count) reference](inflect: true)").inflected().characters),
            group.photoHits.isEmpty ? nil : String(AttributedString(
                localized: "^[\(group.photoHits.count) build photo](inflect: true)").inflected().characters),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// A matching box or moment, indented under its reference.
    @ViewBuilder
    private func childRow(_ match: SearchMatch, in reference: Reference) -> some View {
        switch match.kind {
        case .imageNote(let id, _):
            matchRow(match, systemImage: "rectangle.dashed")
                .tag(SearchResultID.imageNote(reference: reference.id, note: id))
                .help("Open the image at this box")
        case .markup(let id, _, let kind):
            matchRow(match, systemImage: kind.systemImage)
                .tag(SearchResultID.markup(reference: reference.id, markup: id))
                .help("Open the PDF at this \(kind.displayName.lowercased())")
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
        case .kit(let kitID):
            if let kit = results.kits.first(where: { $0.id == kitID }) {
                Button("Edit Kit…") { kitEditor = .edit(kit) }
                Button("Show in Kits") { onShowKit(kit) }
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
        case .reference(let referenceID), .imageNote(let referenceID, _), .markup(let referenceID, _),
             .moment(let referenceID, _):
            if let reference = reference(referenceID, in: results) {
                Button("Open") { activate(id, in: results) }
                Button("Show in Project") { onShowReference(reference) }
                if reference.kind == .pdf, reference.asset != nil {
                    Button("Export Marked-Up Copy…") {
                        Task {
                            do {
                                try await MarkupExporter.saveMarkedUpCopy(of: reference, from: assetLibrary)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
                Divider()
                Button(reference.kind == .note ? "Edit Note…" : "Edit Details…") { detailsReference = reference }
            }
        case .buildPhoto(let photoID), .buildPhotoNote(let photoID, _):
            if let photo = photo(photoID, in: results) {
                Button("Open") { activate(id, in: results) }
                Button("Show in Project") { onShowBuildPhoto(photo) }
                Divider()
                Button("Edit Details…") { detailsPhoto = photo }
            }
        }
    }

    private func activate(_ id: SearchResultID, in results: SearchResults) {
        switch id {
        case .project(let projectID):
            if let project = results.projects.first(where: { $0.id == projectID }) { onShowProject(project) }
        case .kit(let kitID):
            if let kit = results.kits.first(where: { $0.id == kitID }) { kitEditor = .edit(kit) }
        case .paint(let paintID):
            if let paint = results.paints.first(where: { $0.id == paintID }) { paintEditor = .edit(paint) }
        case .aftermarket(let itemID):
            if let item = results.aftermarketItems.first(where: { $0.id == itemID }) { onShowAftermarketItem(item) }
        case .reference(let referenceID):
            if let reference = reference(referenceID, in: results) { open(reference) }
        case .imageNote(let referenceID, let noteID):
            ImageViewerRequests.shared.noteToShow[referenceID] = noteID
            openWindow(id: ImageViewerWindow.id, value: referenceID)
        case .markup(let referenceID, let markupID):
            PDFViewerRequests.shared.markupToShow[referenceID] = markupID
            openWindow(id: PDFViewerWindow.id, value: referenceID)
        case .moment(let referenceID, let seconds):
            if let source = reference(referenceID, in: results)?.sourcePageURL {
                openURL(VideoLink.playbackURL(for: source, at: seconds))
            }
        case .buildPhoto(let photoID):
            openWindow(id: ImageViewerWindow.id, value: photoID)
        case .buildPhotoNote(let photoID, let noteID):
            ImageViewerRequests.shared.noteToShow[photoID] = noteID
            openWindow(id: ImageViewerWindow.id, value: photoID)
        }
    }

    private func photo(_ id: UUID, in results: SearchResults) -> BuildPhoto? {
        for group in results.referenceGroups {
            if let hit = group.photoHits.first(where: { $0.photo.id == id }) { return hit.photo }
        }
        return nil
    }

    /// Opens a reference the same way the gallery does.
    private func open(_ reference: Reference) {
        switch reference.kind {
        case .image:
            openWindow(id: ImageViewerWindow.id, value: reference.id)
        case .pdf:
            openWindow(id: PDFViewerWindow.id, value: reference.id)
        case .markdown:
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
        if !results.kits.isEmpty {
            parts.append(String(AttributedString(localized: "^[\(results.kits.count) kit](inflect: true)").inflected().characters))
        }
        if !results.paints.isEmpty { parts.append(String(localized: "\(results.paints.count) paints")) }
        if !results.aftermarketItems.isEmpty { parts.append(String(localized: "\(results.aftermarketItems.count) parts")) }
        if results.referenceCount > 0 { parts.append(String(localized: "\(results.referenceCount) references")) }
        if results.buildPhotoCount > 0 {
            parts.append(String(AttributedString(
                localized: "^[\(results.buildPhotoCount) build photo](inflect: true)").inflected().characters))
        }
        return parts.joined(separator: " · ")
    }
}

/// A build photo's thumbnail, for small rows.
struct BuildPhotoThumbnail: View {
    let photo: BuildPhoto

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var thumbnail: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            .task(id: photo.asset?.id) {
                if let thumbnailStore, let asset = photo.asset {
                    thumbnail = await thumbnailStore.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
                }
            }
    }
}

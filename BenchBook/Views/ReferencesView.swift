import QuickLook
import SwiftData
import SwiftUI

/// The References section: a filter bar and a grid of tiles, newest first.
struct ReferencesView: View {
    let project: Project
    @Binding var filter: ReferenceFilter
    let onAddFiles: () -> Void

    @Query private var references: [Reference]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    @FocusState private var focusedID: UUID?
    @State private var quickLookURL: URL?
    @State private var detailsReference: Reference?
    @State private var referencePendingDeletion: Reference?
    @State private var errorMessage: String?

    init(project: Project, filter: Binding<ReferenceFilter>, onAddFiles: @escaping () -> Void) {
        self.project = project
        _filter = filter
        self.onAddFiles = onAddFiles
        let projectID = project.id
        _references = Query(
            filter: #Predicate<Reference> { $0.project?.id == projectID },
            sort: [SortDescriptor(\Reference.capturedAt, order: .reverse)]
        )
    }

    var body: some View {
        Group {
            if references.isEmpty {
                ContentUnavailableView {
                    Label("No References", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Drag images, PDFs, Markdown files, links or text here, paste them, or use the Share menu in your browser and choose BenchBook.")
                } actions: {
                    Button("Add Files…", action: onAddFiles)
                }
            } else {
                VStack(spacing: 0) {
                    ReferenceFilterBar(
                        filter: $filter,
                        kinds: kindCounts,
                        tags: tagUsage,
                        totalCount: references.count,
                        matchingCount: visibleReferences.count
                    )
                    Divider()
                    if visibleReferences.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching References", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No references in this project match the type and tags you've chosen.")
                        } actions: {
                            Button("Clear Filters") { filter = ReferenceFilter() }
                        }
                    } else {
                        grid
                    }
                }
            }
        }
        .onChange(of: references.map(\.updatedAt), initial: true) {
            filter.prune(
                availableKinds: Set(kindCounts.map(\.kind)),
                availableTags: Set(tagUsage.map(\.normalizedName))
            )
        }
        .quickLookPreview($quickLookURL, in: previewableURLs)
        .sheet(item: $detailsReference) { reference in
            ReferenceDetailsView(reference: reference)
        }
        .confirmationDialog(
            "Delete “\(referencePendingDeletion?.displayTitle ?? "")”?",
            isPresented: Binding(
                get: { referencePendingDeletion != nil },
                set: { if !$0 { referencePendingDeletion = nil } }
            ),
            presenting: referencePendingDeletion
        ) { reference in
            Button("Delete", role: .destructive) { delete(reference) }
        } message: { _ in
            Text("This removes the reference and its saved copy from BenchBook. This can't be undone.")
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                ForEach(visibleReferences) { reference in
                    ReferenceTile(reference: reference, isSelected: focusedID == reference.id)
                        .focusable()
                        .focused($focusedID, equals: reference.id)
                        .onTapGesture(count: 2) { open(reference) }
                        .onTapGesture { focusedID = reference.id }
                        .onKeyPress(.return) {
                            open(reference)
                            return .handled
                        }
                        .onKeyPress(.space) {
                            quickLook(reference)
                            return .handled
                        }
                        .onDeleteCommand { referencePendingDeletion = reference }
                        .contextMenu { menu(for: reference) }
                        .accessibilityAction(named: "Open") { open(reference) }
                        .accessibilityAction(named: "Edit Details") { detailsReference = reference }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func menu(for reference: Reference) -> some View {
        Button("Open") { open(reference) }
        if reference.asset != nil {
            Button("Quick Look") { quickLook(reference) }
            Button("Open in Default App") { openInDefaultApp(reference) }
        }
        if reference.kind == .videoLink {
            ForEach(reference.sortedVideoMoments) { moment in
                if let source = reference.sourcePageURL {
                    Button("Open at \(VideoLink.format(seconds: moment.offsetSeconds))") {
                        openURL(VideoLink.playbackURL(for: source, at: moment.offsetSeconds))
                    }
                }
            }
        }
        if let source = reference.sourcePageURL, reference.kind != .webpage {
            Button("Open Source Page") { openURL(source) }
        }
        if !reference.tags.isEmpty {
            Menu("Filter by Tag") {
                ForEach(reference.tags) { tag in
                    Button(tag.name) { filter.tags.insert(tag.normalizedName) }
                }
            }
        }
        if let kind = reference.kind {
            Button("Show Only \(kind.pluralName)") { filter.kind = kind }
        }
        Divider()
        Button("Edit Details…") { detailsReference = reference }
        Divider()
        Button("Delete…", role: .destructive) { referencePendingDeletion = reference }
    }

    private var visibleReferences: [Reference] {
        filter.isActive ? references.filter(filter.matches) : references
    }

    /// Types present in the Project, in a fixed order.
    private var kindCounts: [(kind: ReferenceKind, count: Int)] {
        let counts = Dictionary(grouping: references.compactMap(\.kind), by: { $0 }).mapValues(\.count)
        return ReferenceKind.allCases.compactMap { kind in counts[kind].map { (kind, $0) } }
    }

    private var tagUsage: [TagUsage] {
        TagUsage.summarize(references)
    }

    /// Originals of the visible image, PDF and Markdown references, for Quick Look's previous/next.
    private var previewableURLs: [URL] {
        visibleReferences.compactMap { $0.asset.map { assetLibrary.url(forRelativePath: $0.originalRelativePath) } }
    }

    private func open(_ reference: Reference) {
        focusedID = reference.id
        switch reference.kind {
        case .image:
            openWindow(id: ImageViewerWindow.id, value: reference.id)
        case .pdf, .markdown:
            quickLook(reference)
        case .webpage:
            if let url = reference.sourcePageURL { openURL(url) }
        case .videoLink:
            guard let url = reference.sourcePageURL else { return }
            if let first = reference.sortedVideoMoments.first {
                openURL(VideoLink.playbackURL(for: url, at: first.offsetSeconds))
            } else {
                openURL(url)
            }
        case .textSnippet, nil:
            detailsReference = reference
        }
    }

    /// Space bar preview, as in Finder. Non-file references open normally.
    private func quickLook(_ reference: Reference) {
        guard reference.asset != nil else {
            open(reference)
            return
        }
        focusedID = reference.id
        if let url = originalURL(of: reference) {
            quickLookURL = url
        }
    }

    private func openInDefaultApp(_ reference: Reference) {
        guard let url = originalURL(of: reference) else { return }
        NSWorkspace.shared.open(url)
    }

    private func originalURL(of reference: Reference) -> URL? {
        guard let asset = reference.asset else { return nil }
        let url = assetLibrary.url(forRelativePath: asset.originalRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = String(localized: "The saved copy of “\(reference.displayTitle)” is missing from the library.")
            return nil
        }
        return url
    }

    private func delete(_ reference: Reference) {
        do {
            try ReferenceService(context: modelContext, library: assetLibrary).delete(reference)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

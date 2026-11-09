import AppKit
import QuickLook
import SwiftData
import SwiftUI

/// The References section: a filter bar and a grid of tiles, newest first.
struct ReferencesView: View {
    let project: Project
    @Binding var filter: ReferenceFilter
    @Binding var revealID: UUID?
    let onAddFiles: () -> Void
    let onNewNote: () -> Void

    @Query private var references: [Reference]
    @Query(sort: [SortDescriptor(\Tag.name, comparator: .localizedStandard)])
    private var allTags: [Tag]
    @Query(sort: [SortDescriptor(\Project.name, comparator: .localizedStandard)])
    private var allProjects: [Project]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openURL) private var openURL
    @Environment(\.linkInfoService) private var linkInfoService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.transferReferences) private var transferReferences

    /// The tile with keyboard focus.
    @FocusState private var focusedID: UUID?
    /// Selected tiles. ⌘-click adds or removes one, ⇧-click selects a range.
    @State private var selection = Set<UUID>()
    /// Where a ⇧-click range starts.
    @State private var anchorID: UUID?
    /// The tile a dragged tag is over.
    @State private var tagDropTargetID: UUID?
    @State private var tagEditing: TagEditingTarget?
    @State private var quickLookURL: URL?
    @State private var detailsReference: Reference?
    @State private var pendingDeletion: [Reference] = []
    @State private var errorMessage: String?
    @State private var scrollTarget: UUID?

    init(project: Project, filter: Binding<ReferenceFilter>, revealID: Binding<UUID?>,
         onAddFiles: @escaping () -> Void, onNewNote: @escaping () -> Void) {
        self.project = project
        _filter = filter
        _revealID = revealID
        self.onAddFiles = onAddFiles
        self.onNewNote = onNewNote
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
                    Text("Drag images, PDFs, Markdown files, links or text here, paste them, or use the Share menu in your browser and choose BenchBook. You can also write your own notes.")
                } actions: {
                    Button("Add Files…", action: onAddFiles)
                    Button("New Note…", action: onNewNote)
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
        // Show a Reference found by search: clear filters that could hide it.
        .onChange(of: revealID, initial: true) { _, id in
            guard let id, references.contains(where: { $0.id == id }) else { return }
            filter = ReferenceFilter()
            focusedID = id
            selection = [id]
            anchorID = id
            scrollTarget = id
            revealID = nil
        }
        .quickLookPreview($quickLookURL, in: previewableURLs)
        .sheet(item: $detailsReference) { reference in
            if reference.kind == .note {
                NoteEditorView(request: .edit(reference))
            } else {
                ReferenceDetailsView(reference: reference)
            }
        }
        .sheet(item: $tagEditing) { target in
            ReferenceTagsSheet(references: target.references)
        }
        .focusedSceneValue(\.tagAction, selectedReferences.isEmpty ? nil : TagAction {
            tagEditing = TagEditingTarget(references: selectedReferences)
        })
        .confirmationDialog(
            pendingDeletion.count == 1
                ? "Delete “\(pendingDeletion.first?.displayTitle ?? "")”?"
                : "Delete \(pendingDeletion.count) References?",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            )
        ) {
            Button("Delete", role: .destructive) { delete(pendingDeletion) }
        } message: {
            Text(pendingDeletion.count == 1
                 ? "This removes the reference and its saved copy from BenchBook. This can't be undone."
                 : "This removes the references and their saved copies from BenchBook. This can't be undone.")
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
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                ForEach(visibleReferences) { reference in
                    tile(reference)
                }
            }
            .padding(20)
            // Clicking between tiles clears the selection.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
            }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selection = Set(visibleReferences.map(\.id))
        }
        .onExitCommand { clearSelection() }
        .onChange(of: focusedID) { _, id in
            // Moving focus with the keyboard selects that tile alone.
            guard let id, NSApp.currentEvent?.type == .keyDown else { return }
            selection = [id]
            anchorID = id
        }
        .onChange(of: scrollTarget, initial: true) { _, id in
            guard let id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            scrollTarget = nil
        }
        }
    }

    private func tile(_ reference: Reference) -> some View {
        ReferenceTile(reference: reference, isSelected: selection.contains(reference.id))
            .overlay {
                if tagDropTargetID == reference.id {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .id(reference.id)
            .focusable()
            .focused($focusedID, equals: reference.id)
            .onTapGesture(count: 2) { open(reference) }
            .onTapGesture { click(reference) }
            .onKeyPress(.return) {
                open(reference)
                return .handled
            }
            .onKeyPress(.space) {
                quickLook(reference)
                return .handled
            }
            .onDeleteCommand { pendingDeletion = targets(for: reference) }
            .contextMenu { menu(for: targets(for: reference)) }
            // Drag tiles onto a tag in the sidebar to tag them.
            .draggable(ReferencesDragItem(referenceIDs: targets(for: reference).map(\.id))) {
                dragPreview(for: reference)
            }
            // Drop a tag from the sidebar here to tag this tile, or the
            // whole selection when this tile is part of it.
            .dropDestination(for: TagDragItem.self) { items, _ in
                applyDroppedTags(items, to: targets(for: reference))
            } isTargeted: { targeted in
                if targeted {
                    tagDropTargetID = reference.id
                } else if tagDropTargetID == reference.id {
                    tagDropTargetID = nil
                }
            }
            .accessibilityAction(named: "Open") { open(reference) }
            .accessibilityAction(named: "Edit Tags") { tagEditing = TagEditingTarget(references: targets(for: reference)) }
            .accessibilityAction(named: "Edit Details") { detailsReference = reference }
    }

    private func dragPreview(for reference: Reference) -> some View {
        let count = targets(for: reference).count
        return Label(
            count == 1 ? reference.displayTitle : String(localized: "\(count) References"),
            systemImage: count == 1 ? (reference.kind?.systemImage ?? "doc") : "square.stack"
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Selection

    /// Selected References in grid order.
    private var selectedReferences: [Reference] {
        visibleReferences.filter { selection.contains($0.id) }
    }

    /// What an action on `reference` applies to: the whole selection when
    /// the tile is part of it, otherwise just that tile.
    private func targets(for reference: Reference) -> [Reference] {
        selection.contains(reference.id) && selection.count > 1 ? selectedReferences : [reference]
    }

    private func click(_ reference: Reference) {
        let modifiers = NSEvent.modifierFlags
        focusedID = reference.id
        if modifiers.contains(.command) {
            if selection.contains(reference.id) {
                selection.remove(reference.id)
            } else {
                selection.insert(reference.id)
            }
            anchorID = reference.id
        } else if modifiers.contains(.shift), let anchorID,
                  let start = visibleReferences.firstIndex(where: { $0.id == anchorID }),
                  let end = visibleReferences.firstIndex(where: { $0.id == reference.id }) {
            selection = Set(visibleReferences[min(start, end)...max(start, end)].map(\.id))
        } else {
            selection = [reference.id]
            anchorID = reference.id
        }
    }

    private func clearSelection() {
        selection = []
        anchorID = nil
    }

    // MARK: Tags

    private func applyDroppedTags(_ items: [TagDragItem], to references: [Reference]) -> Bool {
        let ids = Set(items.map(\.tagID))
        let dropped = allTags.filter { ids.contains($0.id) }
        guard !dropped.isEmpty else { return false }
        do {
            let service = TagService(context: modelContext)
            for tag in dropped { try service.add(tag, to: references) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Tags with checkmarks. Choosing one adds it to every target, or
    /// removes it when they all have it already.
    @ViewBuilder
    private func tagsMenu(for targets: [Reference]) -> some View {
        Menu("Tags") {
            let service = TagService(context: modelContext)
            ForEach(allTags) { tag in
                let state = service.state(of: tag, on: targets)
                let onCount = targets.filter { reference in reference.tagLinks.contains { $0.tag?.id == tag.id } }.count
                Toggle(isOn: Binding(
                    get: { state == .all },
                    set: { _ in
                        do { try service.toggle(tag, on: targets) } catch { errorMessage = error.localizedDescription }
                    }
                )) {
                    Text(state == .some ? "\(tag.name) (\(onCount) of \(targets.count))" : tag.name)
                }
            }
            if !allTags.isEmpty { Divider() }
            Button("Edit Tags…") { tagEditing = TagEditingTarget(references: targets) }
        }
    }

    @ViewBuilder
    private func menu(for targets: [Reference]) -> some View {
        if targets.count == 1, let reference = targets.first {
            singleMenu(for: reference)
        } else {
            tagsMenu(for: targets)
            Button("Edit Tags…") { tagEditing = TagEditingTarget(references: targets) }
                .keyboardShortcut("t", modifiers: [.command, .control])
            transferMenus(for: targets)
            Divider()
            Button("Delete \(targets.count) References…", role: .destructive) { pendingDeletion = targets }
        }
    }

    @ViewBuilder
    private func singleMenu(for reference: Reference) -> some View {
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
        if reference.hasFetchedPreview, let linkInfoService {
            Button(reference.kind == .webpage ? "Refresh Page Preview" : "Refresh Video Details") {
                Task { await linkInfoService.refresh(reference) }
            }
        }
        Divider()
        tagsMenu(for: [reference])
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
        Button(reference.kind == .note ? "Edit Note…" : "Edit Details…") { detailsReference = reference }
        transferMenus(for: [reference])
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = [reference] }
    }

    /// Move to Project and Copy to Project, listing the other projects.
    @ViewBuilder
    private func transferMenus(for targets: [Reference]) -> some View {
        let others = allProjects.filter { $0.id != project.id }
        if let transferReferences, !others.isEmpty {
            Divider()
            Menu("Move to Project") {
                ForEach(others) { other in
                    Button(other.name) {
                        selection.subtract(targets.map(\.id))
                        transferReferences(targets, to: other, mode: .move)
                    }
                }
            }
            Menu("Copy to Project") {
                ForEach(others) { other in
                    Button(other.name) { transferReferences(targets, to: other, mode: .copy) }
                }
            }
        }
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
        if !selection.contains(reference.id) {
            selection = [reference.id]
            anchorID = reference.id
        }
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
        case .textSnippet, .note, nil:
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

    private func delete(_ chosen: [Reference]) {
        let service = ReferenceService(context: modelContext, library: assetLibrary)
        for reference in chosen {
            do {
                try service.delete(reference)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        selection.subtract(chosen.map(\.id))
    }
}

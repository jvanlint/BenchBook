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
    @Environment(\.appearsActive) private var appearsActive

    /// The tile with keyboard focus.
    @FocusState private var focusedID: UUID?
    /// The last click in this window was in the gallery, so its selection
    /// shows in the accent colour. Keyboard focus can't be used for this:
    /// macOS doesn't keep it on the gallery after a drag across empty space.
    @State private var galleryWasClicked = false
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
    /// The rectangle being dragged to select tiles, in grid coordinates.
    @State private var selectionRect: CGRect?
    /// Tile positions and the drag in progress, kept out of view state.
    @State private var marquee = GalleryMarquee()
    @State private var scrollPosition = ScrollPosition()
    /// So empty space below the last row can start a selection rectangle.
    @State private var viewportHeight: CGFloat = 0

    private static let gridSpace = "referenceGrid"

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
                        // Where each tile is, for selection rectangles. Kept
                        // after it scrolls away, as the rectangle may still reach it.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { frame in
                            marquee.frames[reference.id] = frame
                        }
                        .onAppear { marquee.onScreen.insert(reference.id) }
                        .onDisappear { marquee.onScreen.remove(reference.id) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
            // Clicking between tiles clears the selection; dragging there
            // draws a selection rectangle.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
                    .gesture(selectionDrag)
            }
            .overlay(alignment: .topLeading) {
                if let selectionRect {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1))
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .offset(x: selectionRect.minX, y: selectionRect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.gridSpace))
        }
        .background { ViewAnchor { marquee.galleryView = $0 } }
        .onAppear(perform: watchClicks)
        .onDisappear { marquee.stopWatchingClicks() }
        .onChange(of: focusedID) { old, new in
            // Focus moving from a tile to somewhere else, e.g. ⌘F to search.
            if old != nil, new == nil { galleryWasClicked = false }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        } action: { _, height in
            viewportHeight = height
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            marquee.scroll = geometry
        }
        // Positions of tiles out of view are out of date once the layout changes.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, _ in
            marquee.forgetOffscreenFrames()
        }
        .onChange(of: visibleReferences.map(\.id)) { marquee.forgetOffscreenFrames() }
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
        ReferenceTile(
            reference: reference,
            highlight: TileHighlight(isSelected: selection.contains(reference.id), galleryIsActive: galleryIsActive)
        )
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

    /// Whether selected tiles show in the accent colour: the window is in
    /// front and keyboard focus is in the gallery, not the search field or sidebar.
    private var galleryIsActive: Bool {
        appearsActive && (focusedID != nil || galleryWasClicked || selectionRect != nil)
    }

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

    // MARK: Gallery activity

    /// Notes whether each click in this window lands in the gallery.
    private func watchClicks() {
        marquee.stopWatchingClicks()
        marquee.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if let gallery = marquee.galleryView, event.window === gallery.window {
                    let point = gallery.convert(event.locationInWindow, from: nil)
                    let inside = gallery.bounds.contains(point)
                    if galleryWasClicked != inside { galleryWasClicked = inside }
                }
            }
            return event
        }
    }

    // MARK: Selection rectangle

    /// Dragging across empty space selects the tiles the rectangle touches:
    /// ⇧ adds them to the selection, ⌘ flips them, Esc cancels.
    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in dragSelection(from: value.startLocation, to: value.location) }
            .onEnded { _ in endDragSelection() }
    }

    private func dragSelection(from start: CGPoint, to point: CGPoint) {
        if marquee.drag == nil { beginDragSelection(at: start) }
        guard var drag = marquee.drag, !drag.isCancelled else { return }
        drag.pointerX = point.x
        drag.pointerYInView = point.y - (marquee.scroll?.visibleRect.minY ?? 0)
        marquee.drag = drag
        updateDragSelection(to: point)
        startAutoscroll()
    }

    private func beginDragSelection(at start: CGPoint) {
        let flags = NSEvent.modifierFlags
        marquee.drag = GalleryMarquee.Drag(
            start: start,
            base: selection,
            mode: SelectionRectangle.Mode(command: flags.contains(.command), shift: flags.contains(.shift)),
            pointerX: start.x,
            pointerYInView: start.y - (marquee.scroll?.visibleRect.minY ?? 0)
        )
        marquee.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { cancelDragSelection() }
            return nil
        }
    }

    private func updateDragSelection(to point: CGPoint) {
        guard let drag = marquee.drag else { return }
        let rect = SelectionRectangle.rect(from: drag.start, to: point)
        selectionRect = rect
        let hits = SelectionRectangle.hits(rect, frames: marquee.frames, among: visibleReferences.map(\.id))
        let updated = SelectionRectangle.selection(base: drag.base, hits: hits, mode: drag.mode)
        if updated != selection { selection = updated }
    }

    /// Esc: puts back the selection from before the drag.
    private func cancelDragSelection() {
        guard var drag = marquee.drag else { return }
        drag.isCancelled = true
        marquee.drag = drag
        selection = drag.base
        selectionRect = nil
        marquee.stop()
    }

    private func endDragSelection() {
        marquee.stop()
        // Like Finder, keyboard focus moves into what was selected.
        if marquee.drag?.isCancelled == false, let first = selectedReferences.first {
            anchorID = first.id
        }
        marquee.drag = nil
        selectionRect = nil
    }

    /// Scrolls while the pointer is held near or past the top or bottom,
    /// growing the rectangle with it.
    private func startAutoscroll() {
        guard marquee.autoscroll == nil else { return }
        marquee.autoscroll = Task {
            while !Task.isCancelled, autoscrollStep() {
                try? await Task.sleep(for: .milliseconds(16))
            }
            // A cancelled loop may already have been replaced by a newer one.
            if !Task.isCancelled { marquee.autoscroll = nil }
        }
    }

    /// One step of auto-scrolling; false once the pointer leaves the edges.
    private func autoscrollStep() -> Bool {
        guard let drag = marquee.drag, !drag.isCancelled, let scroll = marquee.scroll else { return false }
        let visible = scroll.visibleRect
        let pointerY = visible.minY + drag.pointerYInView
        let step = SelectionRectangle.autoscrollStep(pointerY: pointerY, visibleMinY: visible.minY, visibleMaxY: visible.maxY)
        guard step != 0 else { return false }
        let lowest = -scroll.contentInsets.top
        let highest = max(lowest, scroll.contentSize.height + scroll.contentInsets.bottom - scroll.containerSize.height)
        let offset = min(max(scroll.contentOffset.y + step, lowest), highest)
        if offset != scroll.contentOffset.y {
            scrollPosition.scrollTo(y: offset)
            updateDragSelection(to: CGPoint(x: drag.pointerX, y: pointerY + offset - scroll.contentOffset.y))
        }
        return true
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
            compareMenu(for: targets)
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

    /// Open Side by Side, when two or more images are selected.
    @ViewBuilder
    private func compareMenu(for targets: [Reference]) -> some View {
        let images = targets.filter { $0.kind == .image }
        if images.count > 1 {
            if ImageComparison.canCompare(images.count) {
                Button("Open Side by Side") { compare(images) }
            } else {
                Button("Open Side by Side (Up to \(ImageComparison.maximumImages) Images)") {}
                    .disabled(true)
            }
            Divider()
        }
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
        // Opening one of several selected images compares them.
        if reference.kind == .image, selection.contains(reference.id) {
            let images = selectedReferences.filter { $0.kind == .image }
            if images.count > 1, ImageComparison.canCompare(images.count) {
                compare(images)
                return
            }
        }
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

    private func compare(_ images: [Reference]) {
        openWindow(id: ImageComparisonWindow.id, value: images.map(\.id))
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
        ImageViewerRequests.shared.willDelete(chosen.map(\.id))
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

/// What rectangle selection needs between updates. Not observed, so tiles
/// appearing and the gallery scrolling don't redraw it.
private final class GalleryMarquee {
    struct Drag {
        let start: CGPoint
        /// The selection when the drag began.
        let base: Set<UUID>
        let mode: SelectionRectangle.Mode
        var pointerX: CGFloat
        /// From the top of the visible area, so auto-scrolling moves the point.
        var pointerYInView: CGFloat
        var isCancelled = false
    }

    /// Tile frames in grid coordinates.
    var frames: [UUID: CGRect] = [:]
    var onScreen = Set<UUID>()
    var scroll: ScrollGeometry?
    var drag: Drag?
    var keyMonitor: Any?
    var autoscroll: Task<Void, Never>?
    /// The AppKit view behind the gallery, for telling where clicks land.
    weak var galleryView: NSView?
    var clickMonitor: Any?

    func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func forgetOffscreenFrames() {
        frames = frames.filter { onScreen.contains($0.key) }
    }

    /// Ends auto-scrolling and stops watching for Esc.
    func stop() {
        autoscroll?.cancel()
        autoscroll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Hands over the AppKit view it's placed behind, once it's in a window.
private struct ViewAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

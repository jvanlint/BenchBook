import AppKit
import QuickLook
import SwiftData
import SwiftUI

/// The Build Photos section: the user's own photos of this build, with
/// completed photos first and work in progress grouped by day.
struct BuildPhotosView: View {
    let project: Project
    /// A photo to scroll to and select, e.g. from search. Cleared once shown.
    @Binding var revealID: UUID?
    let onAddPhotos: () -> Void
    let onImportFromPhotos: () -> Void

    @Query private var photos: [BuildPhoto]
    @Query(sort: [SortDescriptor(\Tag.name, comparator: .localizedStandard)])
    private var allTags: [Tag]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive

    @FocusState private var focusedID: UUID?
    @State private var selection = Set<UUID>()
    /// Where a ⇧-click range starts.
    @State private var anchorID: UUID?
    @State private var tagDropTargetID: UUID?
    @State private var tagEditing: [BuildPhoto]?
    @State private var detailsPhoto: BuildPhoto?
    @State private var pendingDeletion: [BuildPhoto] = []
    @State private var quickLookURL: URL?
    @State private var errorMessage: String?
    @State private var scrollTarget: UUID?
    /// The last click in this window was in the gallery, so its selection
    /// shows in the accent colour and Delete applies to it.
    @State private var galleryWasClicked = false
    /// The rectangle being dragged to select tiles, in grid coordinates.
    @State private var selectionRect: CGRect?
    /// Tile positions and the drag in progress, kept out of view state.
    @State private var marquee = GalleryMarquee()
    @State private var scrollPosition = ScrollPosition()
    /// So empty space below the last row can start a selection rectangle.
    @State private var viewportHeight: CGFloat = 0

    private static let gridSpace = "buildPhotoGrid"

    init(project: Project, revealID: Binding<UUID?>, onAddPhotos: @escaping () -> Void, onImportFromPhotos: @escaping () -> Void) {
        self.project = project
        _revealID = revealID
        self.onAddPhotos = onAddPhotos
        self.onImportFromPhotos = onImportFromPhotos
        let projectID = project.id
        _photos = Query(filter: #Predicate<BuildPhoto> { $0.project?.id == projectID })
    }

    private var service: BuildPhotoService { BuildPhotoService(context: modelContext, library: assetLibrary) }

    private var groups: [BuildPhotoGroup] { BuildPhotoGroup.groups(photos) }

    /// Every photo in grid order, for ⇧-click ranges and Select All.
    private var ordered: [BuildPhoto] { groups.flatMap(\.photos) }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("No Build Photos", systemImage: "camera")
                } description: {
                    Text("Drop photos here, or choose Add Photos…. Keep progress shots and photos of the completed model here, apart from your references.")
                } actions: {
                    Button("Add Photos…", action: onAddPhotos)
                    Button("Import from Photos…", action: onImportFromPhotos)
                }
            } else {
                grid
            }
        }
        .onChange(of: revealID, initial: true) { _, id in
            guard let id, photos.contains(where: { $0.id == id }) else { return }
            focusedID = id
            selection = [id]
            anchorID = id
            scrollTarget = id
            revealID = nil
        }
        .quickLookPreview($quickLookURL, in: ordered.compactMap(originalURL))
        .sheet(item: $detailsPhoto) { photo in
            BuildPhotoDetailsView(photo: photo)
        }
        .sheet(item: Binding(
            get: { tagEditing.map { TagEditingPhotos(photos: $0) } },
            set: { tagEditing = $0?.photos }
        )) { target in
            ReferenceTagsSheet(photos: target.photos)
        }
        .focusedSceneValue(\.tagAction, selectedPhotos.isEmpty ? nil : TagAction { tagEditing = selectedPhotos })
        .confirmationDialog(
            pendingDeletion.count == 1
                ? "Delete This Photo?"
                : "Delete \(pendingDeletion.count) Photos?",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) { delete(pendingDeletion) }
        } message: {
            Text(pendingDeletion.count == 1
                 ? "This removes the photo, its notes and its saved copy from BenchBook. This can't be undone."
                 : "This removes the photos, their notes and their saved copies from BenchBook. This can't be undone.")
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
                LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            groupHeader(group)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                                ForEach(group.photos) { photo in
                                    tile(photo)
                                        // Where each tile is, for selection rectangles. Kept
                                        // after it scrolls away, as the rectangle may still reach it.
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { frame in
                                            marquee.frames[photo.id] = frame
                                        }
                                        .onAppear { marquee.onScreen.insert(photo.id) }
                                        .onDisappear { marquee.onScreen.remove(photo.id) }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .topLeading)
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
            .onDisappear {
                marquee.stopWatchingClicks()
                marquee.stop()
            }
            .onChange(of: focusedID) { old, new in
                // Focus moving to somewhere else with the keyboard, e.g. ⌘F.
                if old != nil, new == nil, NSApp.currentEvent?.type == .keyDown {
                    galleryWasClicked = false
                }
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
            .onChange(of: ordered.map(\.id)) { marquee.forgetOffscreenFrames() }
            .onCommand(#selector(NSResponder.selectAll(_:))) {
                selection = Set(ordered.map(\.id))
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

    private func groupHeader(_ group: BuildPhotoGroup) -> some View {
        HStack(spacing: 6) {
            if group.id == "completed" {
                Image(systemName: BuildPhotoStage.completed.systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(group.title)
                .font(.headline)
            Text(group.photos.count, format: .number)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func tile(_ photo: BuildPhoto) -> some View {
        BuildPhotoTile(
            photo: photo,
            isProjectPhoto: project.projectPhotoID == photo.id,
            highlight: TileHighlight(isSelected: selection.contains(photo.id), galleryIsActive: galleryIsActive)
        )
        .overlay {
            if tagDropTargetID == photo.id {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .id(photo.id)
        .focusable()
        .focused($focusedID, equals: photo.id)
        .onTapGesture(count: 2) { open(photo) }
        .onTapGesture { click(photo) }
        .onKeyPress(.return) {
            open(photo)
            return .handled
        }
        .onKeyPress(.space) {
            quickLook(photo)
            return .handled
        }
        .onDeleteCommand { pendingDeletion = targets(for: photo) }
        .contextMenu { menu(for: targets(for: photo)) }
        // Drag onto a tag in the sidebar to tag, or into a comparison window.
        .draggable(ReferencesDragItem(referenceIDs: targets(for: photo).map(\.id))) {
            dragPreview(for: photo)
        }
        .dropDestination(for: TagDragItem.self) { items, _ in
            applyDroppedTags(items, to: targets(for: photo))
        } isTargeted: { targeted in
            if targeted {
                tagDropTargetID = photo.id
            } else if tagDropTargetID == photo.id {
                tagDropTargetID = nil
            }
        }
        .accessibilityAction(named: "Open") { open(photo) }
        .accessibilityAction(named: "Edit Tags") { tagEditing = targets(for: photo) }
        .accessibilityAction(named: "Edit Details") { detailsPhoto = photo }
    }

    private func dragPreview(for photo: BuildPhoto) -> some View {
        let count = targets(for: photo).count
        return Label(
            count == 1 ? photo.displayTitle : String(AttributedString(localized: "^[\(count) build photo](inflect: true)").inflected().characters),
            systemImage: count == 1 ? "camera" : "square.stack"
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Selection

    private var selectedPhotos: [BuildPhoto] {
        ordered.filter { selection.contains($0.id) }
    }

    /// The whole selection when the photo is part of it, otherwise just that photo.
    private func targets(for photo: BuildPhoto) -> [BuildPhoto] {
        selection.contains(photo.id) && selection.count > 1 ? selectedPhotos : [photo]
    }

    private func click(_ photo: BuildPhoto) {
        let modifiers = NSEvent.modifierFlags
        focusedID = photo.id
        if modifiers.contains(.command) {
            if selection.contains(photo.id) {
                selection.remove(photo.id)
            } else {
                selection.insert(photo.id)
            }
            anchorID = photo.id
        } else if modifiers.contains(.shift), let anchorID,
                  let start = ordered.firstIndex(where: { $0.id == anchorID }),
                  let end = ordered.firstIndex(where: { $0.id == photo.id }) {
            selection = Set(ordered[min(start, end)...max(start, end)].map(\.id))
        } else {
            selection = [photo.id]
            anchorID = photo.id
        }
    }

    private func clearSelection() {
        selection = []
        anchorID = nil
    }

    /// Whether selected tiles show in the accent colour: the window is in
    /// front and the gallery, not the search field or sidebar, was used last.
    private var galleryIsActive: Bool {
        appearsActive && (focusedID != nil || galleryWasClicked || selectionRect != nil)
    }

    // MARK: Gallery activity

    /// Notes whether each click in this window lands in the gallery, and
    /// handles Delete while it does.
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
        // Tiles only get Delete while one has keyboard focus, which a
        // selection rectangle doesn't give them.
        marquee.deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleDelete(event) } ? nil : event
        }
    }

    /// Delete, Forward Delete or ⌘Delete asks to delete the selected photos.
    /// Returns whether it handled the key.
    private func handleDelete(_ event: NSEvent) -> Bool {
        let deleteKeys: Set<UInt16> = [51, 117]  // Delete, Forward Delete
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard deleteKeys.contains(event.keyCode), modifiers.isEmpty || modifiers == .command,
              let gallery = marquee.galleryView, let window = gallery.window,
              event.window === window, window.isKeyWindow,
              galleryIsActive, selectionRect == nil, pendingDeletion.isEmpty,
              !(window.firstResponder is NSText)  // typing in a field
        else { return false }
        let targets = selectedPhotos.isEmpty ? ordered.filter { $0.id == focusedID } : selectedPhotos
        guard !targets.isEmpty else { return false }
        pendingDeletion = targets
        return true
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
        let hits = SelectionRectangle.hits(rect, frames: marquee.frames, among: ordered.map(\.id))
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
        if marquee.drag?.isCancelled == false, let first = selectedPhotos.first {
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

    // MARK: Menus

    @ViewBuilder
    private func menu(for targets: [BuildPhoto]) -> some View {
        if targets.count == 1, let photo = targets.first {
            Button("Open") { open(photo) }
            Button("Quick Look") { quickLook(photo) }
            Button("Open in Default App") { openInDefaultApp(photo) }
            Divider()
            Button("Edit Details…") { detailsPhoto = photo }
            stageButton(for: targets)
            if project.projectPhotoID == photo.id {
                Button("Remove as Project Photo") { perform { try service.setProjectPhoto(nil, for: project) } }
            } else {
                Button("Set as Project Photo") { perform { try service.setProjectPhoto(photo, for: project) } }
            }
            Divider()
            tagsMenu(for: targets)
            Divider()
            Button("Export…") { export(targets) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDeletion = targets }
        } else {
            if ImageComparison.canCompare(targets.count) {
                Button("Open Side by Side") { compare(targets) }
            } else {
                Button("Open Side by Side (Up to \(ImageComparison.maximumImages) Images)") {}
                    .disabled(true)
            }
            Divider()
            stageButton(for: targets)
            tagsMenu(for: targets)
            Divider()
            Button("Export \(targets.count) Photos…") { export(targets) }
            Divider()
            Button("Delete \(targets.count) Photos…", role: .destructive) { pendingDeletion = targets }
        }
    }

    /// Mark as Completed, or as WIP when they're all completed already.
    @ViewBuilder
    private func stageButton(for targets: [BuildPhoto]) -> some View {
        if targets.allSatisfy({ $0.stage == .completed }) {
            Button("Mark as WIP") { perform { try service.setStage(.wip, on: targets) } }
        } else {
            Button("Mark as Completed") { perform { try service.setStage(.completed, on: targets) } }
        }
    }

    /// Tags with checkmarks. Choosing one adds it to every target, or
    /// removes it when they all have it already.
    private func tagsMenu(for targets: [BuildPhoto]) -> some View {
        Menu("Tags") {
            let tags = TagService(context: modelContext)
            ForEach(allTags) { tag in
                let state = tags.state(of: tag, on: targets)
                let onCount = targets.filter { photo in photo.tagLinks.contains { $0.tag?.id == tag.id } }.count
                Toggle(isOn: Binding(
                    get: { state == .all },
                    set: { _ in perform { try tags.toggle(tag, on: targets) } }
                )) {
                    Text(state == .some ? "\(tag.name) (\(onCount) of \(targets.count))" : tag.name)
                }
            }
            if !allTags.isEmpty { Divider() }
            Button("Edit Tags…") { tagEditing = targets }
        }
    }

    private func applyDroppedTags(_ items: [TagDragItem], to targets: [BuildPhoto]) -> Bool {
        let ids = Set(items.map(\.tagID))
        let dropped = allTags.filter { ids.contains($0.id) }
        guard !dropped.isEmpty else { return false }
        let tags = TagService(context: modelContext)
        do {
            for tag in dropped { try tags.add(tag, to: targets) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Actions

    private func open(_ photo: BuildPhoto) {
        focusedID = photo.id
        // Opening one of several selected photos compares them.
        if selection.contains(photo.id), selection.count > 1, ImageComparison.canCompare(selection.count) {
            compare(selectedPhotos)
            return
        }
        if !selection.contains(photo.id) {
            selection = [photo.id]
            anchorID = photo.id
        }
        openWindow(id: ImageViewerWindow.id, value: photo.id)
    }

    private func compare(_ photos: [BuildPhoto]) {
        openWindow(id: ImageComparisonWindow.id, value: photos.map(\.id))
    }

    private func quickLook(_ photo: BuildPhoto) {
        focusedID = photo.id
        if let url = existingOriginalURL(of: photo) { quickLookURL = url }
    }

    private func openInDefaultApp(_ photo: BuildPhoto) {
        if let url = existingOriginalURL(of: photo) { NSWorkspace.shared.open(url) }
    }

    private func originalURL(of photo: BuildPhoto) -> URL? {
        photo.asset.map { assetLibrary.url(forRelativePath: $0.originalRelativePath) }
    }

    private func existingOriginalURL(of photo: BuildPhoto) -> URL? {
        guard let url = originalURL(of: photo), FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = String(localized: "The saved copy of this photo is missing from the library.")
            return nil
        }
        return url
    }

    /// Asks for a folder, then saves copies there. Location data is
    /// removed unless the user turns that off.
    private func export(_ chosen: [BuildPhoto]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export")
        panel.message = chosen.count == 1
            ? String(localized: "Choose a folder for the exported photo.")
            : String(localized: "Choose a folder for the \(chosen.count) exported photos.")
        let removeLocation = NSButton(checkboxWithTitle: String(localized: "Remove location data"), target: nil, action: nil)
        removeLocation.state = .on
        removeLocation.toolTip = String(localized: "Leave out where each photo was taken. The photos in BenchBook aren't changed.")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        removeLocation.frame = NSRect(x: 12, y: 8, width: 240, height: 20)
        accessory.addSubview(removeLocation)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            perform { try service.export(chosen, to: folder, removingLocation: removeLocation.state == .on) }
        }
    }

    private func delete(_ chosen: [BuildPhoto]) {
        ImageViewerRequests.shared.willDelete(chosen.map(\.id))
        perform { try service.delete(chosen) }
        selection.subtract(chosen.map(\.id))
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Build photos whose tags are being edited, for `.sheet(item:)`.
private struct TagEditingPhotos: Identifiable {
    let photos: [BuildPhoto]
    var id: [UUID] { photos.map(\.id) }
}

/// One build photo in the grid: the photo, its caption or date, stage and tags.
struct BuildPhotoTile: View {
    let photo: BuildPhoto
    var isProjectPhoto = false
    var highlight: TileHighlight = .none

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var thumbnail: NSImage?

    private var isOnAccent: Bool { highlight == .emphasized }
    private static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .overlay { preview }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if isProjectPhoto {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                            .help("Project photo")
                            .accessibilityLabel("Project photo")
                    }
                }

            Text(photo.displayTitle)
                .lineLimit(2)
                .foregroundStyle(isOnAccent ? AnyShapeStyle(Self.textOnAccent) : AnyShapeStyle(.primary))

            Label(detailLine, systemImage: photo.stage.systemImage)
                .font(.caption)
                .foregroundStyle(isOnAccent ? AnyShapeStyle(Self.textOnAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)

            if !photo.tags.isEmpty {
                TagChips(tags: photo.tags)
                    .padding(.top, 2)
                    .environment(\.backgroundProminence, isOnAccent ? .increased : .standard)
            }
        }
        .padding(8)
        .background(highlightColor, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .task(id: photo.asset?.id) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(highlight != .none ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// e.g. "WIP · 2 notes" or "Completed · 14:05".
    private var detailLine: String {
        var parts = [photo.stage.displayName]
        if photo.caption != nil {
            parts.append(photo.takenAt.formatted(date: .omitted, time: .shortened))
        }
        let count = photo.markups.count
        if count > 0 {
            parts.append(String(AttributedString(localized: "^[\(count) note](inflect: true)").inflected().characters))
        }
        return parts.joined(separator: " · ")
    }

    private var highlightColor: Color {
        switch highlight {
        case .none: .clear
        case .emphasized: Color(nsColor: .selectedContentBackgroundColor)
        case .unemphasized: Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
    }

    private func loadThumbnail() async {
        guard let thumbnailStore, let asset = photo.asset else { return }
        thumbnail = await thumbnailStore.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
    }
}

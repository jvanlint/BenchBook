import AppKit
import SwiftData
import SwiftUI

/// One image in a comparison: its picture, zoom and selected note.
@Observable
final class ImageComparisonPane {
    var loaded: ImageLoader.Loaded?
    var loadError: String?
    let controller = ImageCanvasController()
    var selection: UUID?
    /// Set to a new note's ID to move the cursor into its text.
    var noteToFocus: UUID?

    var image: CGImage? { loaded?.image }

    var imageSize: CGSize {
        image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }
}

/// Each image's pane while the window is open, so zoom and loaded images
/// survive layout changes. Not observed: panes are made on first use,
/// while views update.
final class ImageComparisonPanes {
    private var panes: [UUID: ImageComparisonPane] = [:]

    func pane(for id: UUID) -> ImageComparisonPane {
        if let pane = panes[id] { return pane }
        let pane = ImageComparisonPane()
        panes[id] = pane
        return pane
    }

    func keep(only ids: [UUID]) {
        panes = panes.filter { ids.contains($0.key) }
    }
}

/// Up to four images side by side or in a grid, each zoomed on its own,
/// with one Notes and Info panel for the image last clicked. The window's
/// value is the images' Reference IDs, so it reopens after relaunch.
struct ImageComparisonWindow: View {
    static let id = "image-comparison"

    @Binding var referenceIDs: [UUID]?
    @Environment(\.modelContext) private var modelContext

    @State private var panes = ImageComparisonPanes()
    @State private var activeID: UUID?
    /// One image filling the window for a closer look.
    @State private var expandedID: UUID?
    /// Row or grid as last chosen in this window; empty follows the image count.
    @SceneStorage("imageComparison.arrangement") private var chosenArrangement = ""
    @State private var showsBoxes = AppSettings.showsNoteBoxes()
    @State private var showsInspector = true
    @AppStorage("imageViewer.inspectorTab") private var inspectorTab = ImageInspectorTab.notes
    @State private var dropTarget: DropTarget?
    @State private var showsAddSlot = false
    @State private var notePendingDeletion: ImageNote?
    @State private var errorMessage: String?

    private enum DropTarget: Equatable {
        case pane(UUID)
        case add
    }

    private var service: ImageNoteService { ImageNoteService(context: modelContext) }

    private var ids: [UUID] { referenceIDs ?? [] }

    var body: some View {
        let references = images(ids.filter { !ImageViewerRequests.shared.deletedReferences.contains($0) })
        if let active = references.first(where: { $0.id == activeID }) ?? references.first {
            comparison(references, active: active)
        } else {
            ContentUnavailableView(
                "Images Not Found",
                systemImage: "photo.badge.exclamationmark",
                description: Text("These images may have been deleted.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }

    private func comparison(_ references: [Reference], active: Reference) -> some View {
        let pane = panes.pane(for: active.id)
        let arrangement = arrangement(for: references.count)
        let shown = references.contains { $0.id == expandedID } ? references.filter { $0.id == expandedID } : references

        return ComparisonLayout(arrangement: arrangement) {
            ForEach(shown, id: \.id) { reference in
                paneView(reference, in: references, isActive: reference.id == active.id)
            }
            if showsAddSlot, shown.count == references.count, references.count < ImageComparison.maximumImages {
                addSlot
            }
        }
        .background(Color(nsColor: .separatorColor))
        .ignoresSafeArea(edges: .bottom)
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(active.displayTitle)
        .navigationSubtitle(subtitle(references, active: active))
        .inspector(isPresented: $showsInspector) {
            inspector(for: active, pane: pane, isComparing: references.count > 1)
        }
        .toolbar { toolbar(references, active: active, pane: pane, arrangement: arrangement) }
        .onChange(of: references.map(\.id), initial: true) { _, shown in tidy(keeping: shown) }
        .onChange(of: activeID) { commit() }
        .onChange(of: pane.selection) { commit() }
        .onDisappear { commit() }
        // You can't draw boxes you can't see, so drawing shows them.
        .onChange(of: pane.controller.isDrawing) { _, drawing in
            if drawing { showsBoxes = true }
        }
        .onChange(of: showsBoxes) { _, shown in
            if !shown { pane.controller.isDrawing = false }
        }
        .confirmationDialog(
            "Delete Note?",
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            ),
            presenting: notePendingDeletion
        ) { note in
            Button("Delete", role: .destructive) { delete(note) }
        } message: { _ in
            Text("The box and its note will be removed. The image isn't changed.")
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

    private func paneView(_ reference: Reference, in references: [Reference], isActive: Bool) -> some View {
        ImageComparisonPaneView(
            reference: reference,
            pane: panes.pane(for: reference.id),
            isActive: isActive && references.count > 1,
            isExpanded: expandedID == reference.id,
            isComparing: references.count > 1,
            showsBoxes: showsBoxes,
            isDropTarget: dropTarget == .pane(reference.id),
            actions: ImageComparisonPaneView.Actions(
                activate: { activate(reference.id) },
                toggleExpanded: { toggleExpanded(reference.id) },
                remove: { remove(reference.id) },
                create: { create($0, on: reference) },
                move: { move($0, to: $1, on: reference) },
                delete: { id in notePendingDeletion = reference.sortedImageNotes.first { $0.id == id } }
            )
        )
        // Dropping images from a gallery replaces this one.
        .dropDestination(for: ReferencesDragItem.self) { items, _ in
            replace(reference.id, with: items)
        } isTargeted: { targeted in
            dropHover(.pane(reference.id), targeted)
        }
    }

    /// Appears while images are dragged over the window, if there's room.
    private var addSlot: some View {
        ContentUnavailableView {
            Label("Add to Comparison", systemImage: "plus.rectangle.on.rectangle")
        } description: {
            Text("Drop images here to compare them too.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTarget == .add ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: ReferencesDragItem.self) { items, _ in
            add(items)
        } isTargeted: { targeted in
            dropHover(.add, targeted)
        }
    }

    private func inspector(for reference: Reference, pane: ImageComparisonPane, isComparing: Bool) -> some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $inspectorTab) {
                ForEach(ImageInspectorTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            if isComparing {
                // Says which image the panel describes; click another image to switch.
                Text(reference.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            switch inspectorTab {
            case .notes:
                ImageNotesPanel(
                    notes: reference.sortedImageNotes,
                    selection: Bindable(pane).selection,
                    noteToFocus: Bindable(pane).noteToFocus,
                    service: service,
                    onDelete: { notePendingDeletion = $0 }
                )
            case .info:
                ImageInfoPanel(reference: reference, loaded: pane.loaded)
            }
        }
        // A fresh panel for each image, so typing focus doesn't carry over.
        .id(reference.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
    }

    @ToolbarContentBuilder
    private func toolbar(
        _ references: [Reference], active: Reference, pane: ImageComparisonPane, arrangement: ImageComparison.Arrangement
    ) -> some ToolbarContent {
        let controller = pane.controller
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous Image", systemImage: "chevron.left") { step(active, by: -1) }
                .keyboardShortcut("[")
                .disabled(neighbour(of: active, offset: -1) == nil)
                .help("Show the previous image from this project here (⌘[)")

            Button("Next Image", systemImage: "chevron.right") { step(active, by: 1) }
                .keyboardShortcut("]")
                .disabled(neighbour(of: active, offset: 1) == nil)
                .help("Show the next image from this project here (⌘])")
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("Arrangement", selection: Binding(
                get: { arrangement },
                set: { chosenArrangement = $0.rawValue }
            )) {
                Label("Side by Side", systemImage: "rectangle.split.3x1").tag(ImageComparison.Arrangement.row)
                Label("Grid", systemImage: references.count == 2 ? "rectangle.split.1x2" : "square.grid.2x2")
                    .tag(ImageComparison.Arrangement.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(references.count < 2 || expandedID != nil)
            .help(references.count == 2 ? "Side by side or one above the other" : "Side by side or in a grid")

            Toggle(isOn: $showsBoxes) {
                Label(showsBoxes ? "Hide Boxes" : "Show Boxes", systemImage: showsBoxes ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .keyboardShortcut("b")
            .help(showsBoxes ? "Hide boxes on every image (⌘B)" : "Show boxes on every image (⌘B)")

            Toggle(isOn: Bindable(controller).isDrawing) {
                Label("Draw Box", systemImage: "rectangle.dashed.badge.record")
            }
            .toggleStyle(.button)
            .keyboardShortcut("d")
            .disabled(pane.image == nil)
            .help("Draw a box on the selected image, then describe it (⌘D)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoomOut() }
                    .keyboardShortcut("-")
                    .help("Zoom Out (⌘−)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoomIn() }
                    .keyboardShortcut("=")
                    .help("Zoom In (⌘=)")
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
            .disabled(pane.image == nil)

            Text("\(controller.zoomPercent)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
                .accessibilityLabel("Zoom \(controller.zoomPercent) percent")

            Button("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left") { controller.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(pane.image == nil)
                .help("Zoom to Fit (⌘9)")

            Button("Actual Size", systemImage: "1.magnifyingglass") { controller.actualSize() }
                .keyboardShortcut("0")
                .disabled(pane.image == nil)
                .help("Actual Size (⌘0)")

            Button("Notes and Info", systemImage: "sidebar.right") { showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showsInspector ? "Hide Notes and Info (⌥⌘I)" : "Show Notes and Info (⌥⌘I)")
        }
    }

    /// e.g. "Comparing 3 images" or, for one image, its project.
    private func subtitle(_ references: [Reference], active: Reference) -> String {
        guard references.count > 1 else { return active.project?.name ?? "" }
        return String(AttributedString(localized: "Comparing ^[\(references.count) image](inflect: true)").inflected().characters)
    }

    private func arrangement(for count: Int) -> ImageComparison.Arrangement {
        ImageComparison.Arrangement(rawValue: chosenArrangement) ?? ImageComparison.defaultArrangement(for: count)
    }

    // MARK: Images

    /// The images among `ids`, in that order.
    private func images(_ ids: [UUID]) -> [Reference] {
        guard !ids.isEmpty else { return [] }
        let found = (try? modelContext.fetch(FetchDescriptor<Reference>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { $0.kind == .image }
    }

    /// Drops deleted images from the window and forgets their panes.
    private func tidy(keeping shown: [UUID]) {
        if shown != ids { referenceIDs = shown }
        panes.keep(only: shown)
        if let activeID, !shown.contains(activeID) { self.activeID = shown.first }
        if activeID == nil { activeID = shown.first }
        if let expandedID, !shown.contains(expandedID) { self.expandedID = nil }
    }

    private func activate(_ id: UUID) {
        guard activeID != id else { return }
        // Drawing belongs to the image it started on.
        if let activeID { panes.pane(for: activeID).controller.isDrawing = false }
        activeID = id
    }

    private func toggleExpanded(_ id: UUID) {
        activate(id)
        expandedID = expandedID == id ? nil : id
    }

    private func remove(_ id: UUID) {
        guard ids.count > 1 else { return }
        commit()
        referenceIDs = ids.filter { $0 != id }
    }

    /// Images in the same Project, newest first, as in the gallery.
    private func siblings(of reference: Reference) -> [UUID] {
        (reference.project?.references ?? [])
            .filter { $0.kind == .image }
            .sorted { $0.capturedAt > $1.capturedAt }
            .map(\.id)
    }

    private func neighbour(of reference: Reference, offset: Int) -> UUID? {
        ImageComparison.neighbour(of: reference.id, offset: offset, in: siblings(of: reference), skipping: ids)
    }

    /// Shows the previous or next image from the same project in the selected pane.
    private func step(_ reference: Reference, by offset: Int) {
        guard let next = neighbour(of: reference, offset: offset) else { return }
        commit()
        referenceIDs = ids.map { $0 == reference.id ? next : $0 }
        if expandedID == reference.id { expandedID = next }
        activeID = next
    }

    // MARK: Dropping

    private func droppedImages(_ items: [ReferencesDragItem]) -> [UUID] {
        images(items.flatMap(\.referenceIDs)).map(\.id)
    }

    private func replace(_ target: UUID, with items: [ReferencesDragItem]) -> Bool {
        endDrop()
        let added = droppedImages(items)
        guard let first = added.first else { return false }
        referenceIDs = ImageComparison.replacing(target, with: added, in: ids)
        activeID = first
        return true
    }

    private func add(_ items: [ReferencesDragItem]) -> Bool {
        endDrop()
        let added = droppedImages(items).filter { !ids.contains($0) }
        guard let first = added.first else { return false }
        referenceIDs = ImageComparison.adding(added, to: ids)
        if referenceIDs?.contains(first) == true { activeID = first }
        expandedID = nil
        return true
    }

    /// Shows the add slot while a drag is over any part of the window.
    /// Hiding waits a moment, as moving between drop areas briefly leaves both.
    private func dropHover(_ target: DropTarget, _ targeted: Bool) {
        if targeted {
            dropTarget = target
            showsAddSlot = true
        } else if dropTarget == target {
            dropTarget = nil
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if dropTarget == nil { showsAddSlot = false }
            }
        }
    }

    private func endDrop() {
        dropTarget = nil
        showsAddSlot = false
    }

    // MARK: Notes

    private func create(_ rect: CGRect, on reference: Reference) {
        let pane = panes.pane(for: reference.id)
        do {
            if let note = try service.addNote(to: reference, pixelRect: rect, imageSize: pane.imageSize) {
                activate(reference.id)
                pane.selection = note.id
                showsInspector = true
                inspectorTab = .notes
                pane.noteToFocus = note.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(_ id: UUID, to rect: CGRect, on reference: Reference) {
        guard let note = reference.sortedImageNotes.first(where: { $0.id == id }) else { return }
        do {
            try service.move(note, toPixelRect: rect, imageSize: panes.pane(for: reference.id).imageSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ note: ImageNote) {
        if let id = note.reference?.id {
            let pane = panes.pane(for: id)
            if pane.selection == note.id { pane.selection = nil }
        }
        do {
            try service.delete(note)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        do {
            try service.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One image in the comparison window, with a title bar.
private struct ImageComparisonPaneView: View {
    struct Actions {
        var activate: () -> Void
        var toggleExpanded: () -> Void
        var remove: () -> Void
        var create: (CGRect) -> Void
        var move: (UUID, CGRect) -> Void
        var delete: (UUID) -> Void
    }

    let reference: Reference
    @Bindable var pane: ImageComparisonPane
    /// The image the toolbar and Notes panel act on.
    let isActive: Bool
    let isExpanded: Bool
    /// More than one image in the window.
    let isComparing: Bool
    let showsBoxes: Bool
    let isDropTarget: Bool
    let actions: Actions

    @Environment(\.assetLibrary) private var assetLibrary

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if isActive {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTarget {
                ZStack {
                    Color.accentColor.opacity(0.18)
                    Label("Replace This Image", systemImage: "arrow.left.arrow.right")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .task(id: reference.id) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reference.displayTitle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(reference.displayTitle)
                    .fontWeight(isActive ? .semibold : .regular)
                    .layoutPriority(1)
                if let project = reference.project?.name {
                    Text(project)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isComparing {
                Button(
                    isExpanded ? "Show All Images" : "Fill Window",
                    systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    action: actions.toggleExpanded
                )
                .help(isExpanded ? "Show all the images again (or double-click the image)" : "Show only this image (or double-click it)")

                Button("Remove from Comparison", systemImage: "xmark", action: actions.remove)
                    .help("Remove this image from the window")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { actions.activate() }
    }

    @ViewBuilder
    private var content: some View {
        if let image = pane.image {
            ImageCanvas(
                image: image,
                notes: NoteBox.boxes(for: reference.sortedImageNotes, in: pane.imageSize),
                showsBoxes: showsBoxes,
                selection: $pane.selection,
                controller: pane.controller,
                onCreate: actions.create,
                onMove: actions.move,
                onDelete: actions.delete,
                onClick: actions.activate,
                onDoubleClick: isComparing ? actions.toggleExpanded : nil
            )
        } else if let loadError = pane.loadError {
            ContentUnavailableView("Can't Show Image", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Once per pane; the pane keeps the image when the layout changes.
    private func load() async {
        guard pane.loaded == nil, pane.loadError == nil else { return }
        do {
            pane.loaded = try await ImageLoader.load(reference, from: assetLibrary)
        } catch {
            pane.loadError = error.localizedDescription
        }
    }
}

/// Splits the window evenly into rows of images, 1 point apart.
private struct ComparisonLayout: Layout {
    var arrangement: ImageComparison.Arrangement
    var spacing: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 900, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = ImageComparison.rows(count: subviews.count, arrangement: arrangement)
        guard !rows.isEmpty else { return }
        let height = (bounds.height - spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        for (rowIndex, row) in rows.enumerated() {
            let width = (bounds.width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count)
            for (column, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: bounds.minY + CGFloat(rowIndex) * (height + spacing)),
                    proposal: ProposedViewSize(width: width, height: height)
                )
            }
        }
    }
}

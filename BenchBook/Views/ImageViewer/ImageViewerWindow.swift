import SwiftData
import SwiftUI

/// Root of an image viewer window. The window's value is the Reference ID,
/// so previous/next simply changes it.
struct ImageViewerWindow: View {
    static let id = "image-viewer"

    @Binding var referenceID: UUID?
    @Environment(\.modelContext) private var modelContext

    private var reference: Reference? {
        guard let referenceID else { return nil }
        return try? modelContext.fetch(FetchDescriptor<Reference>(predicate: #Predicate { $0.id == referenceID })).first
    }

    var body: some View {
        if let reference, reference.kind == .image {
            ImageViewer(reference: reference) { referenceID = $0 }
                .id(reference.id)
        } else {
            ContentUnavailableView(
                "Image Not Found",
                systemImage: "photo.badge.exclamationmark",
                description: Text("This image may have been deleted.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Asks an image viewer to show one of its notes, e.g. from search.
/// Keyed by Reference ID; the viewer clears the request once shown.
@Observable
final class ImageViewerRequests {
    static let shared = ImageViewerRequests()
    var noteToShow: [UUID: UUID] = [:]
    /// References deleted this session, so comparison windows drop them.
    private(set) var deletedReferences = Set<UUID>()

    /// Call before deleting references that a viewer might show.
    func willDelete(_ ids: some Sequence<UUID>) {
        deletedReferences.formUnion(ids)
    }
}

extension ImageLoader {
    /// Why a reference's image can't be shown, in words for the user.
    nonisolated enum ReferenceError: LocalizedError {
        case noImage, missingFile

        var errorDescription: String? {
            switch self {
            case .noImage: String(localized: "This reference has no saved image.")
            case .missingFile: String(localized: "The saved copy of this image is missing from the library.")
            }
        }
    }

    /// Loads a reference's saved image off the main thread.
    @MainActor
    static func load(_ reference: Reference, from library: AssetLibrary) async throws -> Loaded {
        guard let asset = reference.asset else { throw ReferenceError.noImage }
        let url = library.url(forRelativePath: asset.originalRelativePath)
        do {
            return try await Task.detached(priority: .userInitiated) { try ImageLoader.load(url) }.value
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { throw error }
            throw ReferenceError.missingFile
        }
    }
}

extension NoteBox {
    /// The numbered boxes for an image's notes, in image pixels.
    @MainActor
    static func boxes(for notes: [Markup], in imageSize: CGSize) -> [NoteBox] {
        notes.enumerated().map { index, note in
            NoteBox(
                id: note.id,
                rect: NoteGeometry.pixelRect(x: note.x, y: note.y, width: note.width, height: note.height, in: imageSize),
                number: index + 1
            )
        }
    }
}

/// The viewer's side panel tabs.
enum ImageInspectorTab: String, CaseIterable {
    case notes, info

    var title: LocalizedStringKey {
        switch self {
        case .notes: "Notes"
        case .info: "Info"
        }
    }
}

/// Shows one image with zoom, pan and note boxes, plus a Notes/Info panel.
struct ImageViewer: View {
    let reference: Reference
    let onNavigate: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary

    @State private var loaded: ImageLoader.Loaded?
    @AppStorage("imageViewer.inspectorTab") private var inspectorTab = ImageInspectorTab.notes
    @State private var loadError: String?
    @State private var controller = ImageCanvasController()
    @State private var selection: UUID?
    @State private var showsNotes = true
    /// Remembered across windows and launches.
    /// Starts as set in Settings; ⌘B changes it for this image only.
    @State private var showsBoxes = AppSettings.showsNoteBoxes()
    @State private var noteToFocus: UUID?
    @State private var notePendingDeletion: Markup?
    @State private var errorMessage: String?

    private var service: ImageNoteService { ImageNoteService(context: modelContext) }

    private var image: CGImage? { loaded?.image }

    private var imageSize: CGSize {
        image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    private var notes: [Markup] { reference.sortedImageNotes }

    private var noteBoxes: [NoteBox] { NoteBox.boxes(for: notes, in: imageSize) }

    /// Images in the same Project, newest first, as in the gallery.
    private var siblings: [Reference] {
        (reference.project?.references ?? [])
            .filter { $0.kind == .image }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private func sibling(offset: Int) -> Reference? {
        guard let index = siblings.firstIndex(where: { $0.id == reference.id }) else { return nil }
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target] : nil
    }

    var body: some View {
        content
            .frame(minWidth: 520, minHeight: 360)
            .navigationTitle(reference.displayTitle)
            .navigationSubtitle(subtitle)
            .inspector(isPresented: $showsNotes) {
                VStack(spacing: 0) {
                    Picker("Panel", selection: $inspectorTab) {
                        ForEach(ImageInspectorTab.allCases, id: \.self) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)

                    switch inspectorTab {
                    case .notes:
                        ImageNotesPanel(
                            notes: notes,
                            selection: $selection,
                            noteToFocus: $noteToFocus,
                            service: service,
                            onDelete: { notePendingDeletion = $0 }
                        )
                    case .info:
                        ImageInfoPanel(reference: reference, loaded: loaded)
                    }
                }
                // Keep the tab switch pinned to the top, whatever is below it.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
            }
            .toolbar { toolbar }
            .task(id: reference.id) { await loadImage() }
            .task(id: RequestedNote(noteID: ImageViewerRequests.shared.noteToShow[reference.id], isLoaded: image != nil)) {
                await showRequestedNote()
            }
            .onDisappear { commit() }
            .onChange(of: selection) { commit() }
            // You can't draw boxes you can't see, so drawing shows them.
            .onChange(of: controller.isDrawing) { _, drawing in
                if drawing { showsBoxes = true }
            }
            .onChange(of: showsBoxes) { _, shown in
                if !shown { controller.isDrawing = false }
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

    @ViewBuilder
    private var content: some View {
        if let image {
            ImageCanvas(
                image: image,
                notes: noteBoxes,
                showsBoxes: showsBoxes,
                selection: $selection,
                controller: controller,
                onCreate: create,
                onMove: move,
                onDelete: { id in notePendingDeletion = notes.first { $0.id == id } }
            )
            .ignoresSafeArea(edges: .bottom)
        } else if let loadError {
            ContentUnavailableView("Can't Show Image", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous Image", systemImage: "chevron.left") {
                if let previous = sibling(offset: -1) { onNavigate(previous.id) }
            }
            .keyboardShortcut("[")
            .disabled(sibling(offset: -1) == nil)
            .help("Previous Image (⌘[)")

            Button("Next Image", systemImage: "chevron.right") {
                if let next = sibling(offset: 1) { onNavigate(next.id) }
            }
            .keyboardShortcut("]")
            .disabled(sibling(offset: 1) == nil)
            .help("Next Image (⌘])")
        }

        ToolbarItemGroup(placement: .principal) {
            Toggle(isOn: $showsBoxes) {
                Label(showsBoxes ? "Hide Boxes" : "Show Boxes", systemImage: showsBoxes ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .keyboardShortcut("b")
            .disabled(image == nil)
            .help(showsBoxes ? "Hide boxes to see the whole image (⌘B)" : "Show boxes (⌘B)")

            Toggle(isOn: $controller.isDrawing) {
                Label("Draw Box", systemImage: "rectangle.dashed.badge.record")
            }
            .toggleStyle(.button)
            .keyboardShortcut("d")
            .disabled(image == nil)
            .help("Draw a box around a feature, then describe it (⌘D)")
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
            .disabled(image == nil)

            Text("\(controller.zoomPercent)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
                .accessibilityLabel("Zoom \(controller.zoomPercent) percent")

            Button("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left") { controller.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(image == nil)
                .help("Zoom to Fit (⌘9)")

            Button("Actual Size", systemImage: "1.magnifyingglass") { controller.actualSize() }
                .keyboardShortcut("0")
                .disabled(image == nil)
                .help("Actual Size (⌘0)")

            Button("Notes and Info", systemImage: "sidebar.right") { showsNotes.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showsNotes ? "Hide Notes and Info (⌥⌘I)" : "Show Notes and Info (⌥⌘I)")
        }
    }

    /// e.g. "F-16CJ · 4,032 × 3,024".
    private var subtitle: String {
        var parts = [reference.project?.name].compactMap { $0 }
        if let metadata = loaded?.metadata {
            parts.append("\(metadata.pixelWidth.formatted()) × \(metadata.pixelHeight.formatted())")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func loadImage() async {
        do {
            loaded = try await ImageLoader.load(reference, from: assetLibrary)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private struct RequestedNote: Equatable {
        let noteID: UUID?
        let isLoaded: Bool
    }

    /// Selects the requested note and zooms to its box, once the image is shown.
    private func showRequestedNote() async {
        guard image != nil, let id = ImageViewerRequests.shared.noteToShow[reference.id] else { return }
        ImageViewerRequests.shared.noteToShow[reference.id] = nil
        guard let box = noteBoxes.first(where: { $0.id == id }) else { return }
        showsBoxes = true
        showsNotes = true
        inspectorTab = .notes
        selection = id
        // Let the canvas lay out at its window size before zooming.
        try? await Task.sleep(for: .milliseconds(150))
        controller.zoom(toPixelRect: box.rect)
    }

    private func create(_ rect: CGRect) {
        do {
            if let note = try service.addNote(to: reference, pixelRect: rect, imageSize: imageSize) {
                selection = note.id
                showsNotes = true
                inspectorTab = .notes
                noteToFocus = note.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(_ id: UUID, _ rect: CGRect) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        do {
            try service.move(note, toPixelRect: rect, imageSize: imageSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ note: Markup) {
        if selection == note.id { selection = nil }
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

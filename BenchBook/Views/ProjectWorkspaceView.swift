import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case kits
    case references
    case paint
    case aftermarket
    case buildPhotos

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .kits: "Kits"
        case .references: "References"
        case .paint: "Paint"
        case .aftermarket: "Aftermarket"
        case .buildPhotos: "Build Photos"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .kits: "1"
        case .references: "2"
        case .paint: "3"
        case .aftermarket: "4"
        case .buildPhotos: "5"
        }
    }
}

struct ProjectWorkspaceView: View {
    let project: Project
    let onEdit: () -> Void
    let onAddFiles: () -> Void
    /// Shows a kit in the Kits catalogue.
    let onShowKit: (Kit) -> Void
    /// A Reference to scroll to and select, e.g. from search. Cleared once shown.
    @Binding var revealReferenceID: UUID?
    /// An aftermarket part to select, e.g. from search. Cleared once shown.
    @Binding var revealAftermarketID: UUID?
    /// A build photo to select, e.g. from search. Cleared once shown.
    @Binding var revealBuildPhotoID: UUID?

    @Environment(\.captureCoordinator) private var captureCoordinator
    @Environment(\.appearsActive) private var appearsActive
    @State private var pasteOwner = UUID()
    @State private var section: WorkspaceSection = .references
    /// Kept here so it survives switching sections; resets per Project.
    @State private var referenceFilter = ReferenceFilter()
    @State private var isDropTargeted = false
    @State private var noteRequest: NoteEditorView.Request?
    @State private var isAddingPhotos = false
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var photoReport: CaptureReport?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        workspace
            .focusedSceneValue(\.workspaceSection, $section)
            .onChange(of: revealReferenceID, initial: true) { _, id in
                if id != nil { section = .references }
            }
            .onChange(of: revealAftermarketID, initial: true) { _, id in
                if id != nil { section = .aftermarket }
            }
            .onChange(of: revealBuildPhotoID, initial: true) { _, id in
                if id != nil { section = .buildPhotos }
            }
            .fileImporter(isPresented: $isAddingPhotos, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    addBuildPhotos(urls.map { ($0, $0.lastPathComponent) })
                }
            }
            .photosPicker(isPresented: $isPickingPhotos, selection: $pickedPhotos, matching: .images,
                          preferredItemEncoding: .current)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                importPicked(items)
            }
            .alert(
                photoReport?.title ?? "",
                isPresented: Binding(get: { photoReport != nil }, set: { if !$0 { photoReport = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(photoReport?.message ?? "")
            }
            .focusedSceneValue(\.noteAction, noteRequest == nil ? NoteAction(newNote: newNote) : nil)
            .sheet(item: $noteRequest) { request in
                NoteEditorView(request: request)
            }
    }

    private var workspace: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: CaptureDrop.types, isTargeted: $isDropTargeted) { providers in
                let providers = CaptureDrop.providers(fallback: providers)
                if section == .buildPhotos {
                    addBuildPhotos(from: providers)
                } else {
                    capture(providers)
                }
                return true
            }
            // ⌘V pastes into the project shown in the front window.
            .onChange(of: appearsActive, initial: true) { _, active in
                if active {
                    PasteRouter.shared.register(owner: pasteOwner) { providers in
                        if section == .buildPhotos {
                            addBuildPhotos(from: providers)
                        } else {
                            capture(providers)
                        }
                    }
                }
            }
            .onDisappear { PasteRouter.shared.unregister(owner: pasteOwner) }
            .navigationTitle(project.name)
            .navigationSubtitle(project.summary)
            .toolbar {
                if let photo = project.projectPhoto {
                    ToolbarItem(placement: .navigation) {
                        ProjectPhotoButton(photo: photo) {
                            openWindow(id: ImageViewerWindow.id, value: photo.id)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(WorkspaceSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Switch between Kits, References, Paint, Aftermarket and Build Photos")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if section == .buildPhotos {
                        Button("Add Photos", systemImage: "photo.badge.plus") { isAddingPhotos = true }
                            .help("Add photos of this build from your files")
                        Button("Import from Photos", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                            .help("Choose photos of this build from your Photos library")
                    } else {
                        Button("Add Files", systemImage: "plus.rectangle.on.rectangle", action: addFiles)
                            .help("Add images, PDFs or Markdown files to this project")
                        Button("New Note", systemImage: "square.and.pencil", action: newNote)
                            .help("Write a note in this project's references")
                    }
                    Button("Edit Project", systemImage: "pencil", action: onEdit)
                        .help("Edit Project")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .kits:
            ProjectKitsView(project: project, onShowKit: onShowKit)
        case .references:
            ReferencesView(project: project, filter: $referenceFilter, revealID: $revealReferenceID,
                           onAddFiles: addFiles, onNewNote: newNote)
        case .paint:
            ProjectPaintView(project: project)
        case .aftermarket:
            ProjectAftermarketView(project: project, revealID: $revealAftermarketID)
        case .buildPhotos:
            BuildPhotosView(project: project, revealID: $revealBuildPhotoID,
                            onAddPhotos: { isAddingPhotos = true },
                            onImportFromPhotos: { isPickingPhotos = true })
                // An iPhone or iPad photo becomes a build photo.
                .takesCameraPhotos { addBuildPhotos(from: $0) }
        }
    }

    /// Shows References with no filters, so the new note is visible.
    private func newNote() {
        section = .references
        referenceFilter = ReferenceFilter()
        noteRequest = .new(project)
    }

    private func addFiles() {
        referenceFilter = ReferenceFilter()
        onAddFiles()
    }

    // MARK: Build photos

    /// Dropped or pasted images become build photos. Anything else is reported.
    private func addBuildPhotos(from providers: [NSItemProvider]) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "BenchBook-BuildPhotos-\(UUID().uuidString)", directoryHint: .isDirectory)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let result = await ItemProviderReader(fileDirectory: folder, copiesFileURLs: true).read(providers)
            var files: [(URL, String?)] = []
            var skipped = result.skipped
            for item in result.items {
                switch item {
                case .file(let url, let filename, _): files.append((url, filename))
                case .link(let url, let title): skipped.append(title ?? url.absoluteString)
                case .text(let text, _, let title): skipped.append(title ?? String(text.prefix(40)))
                }
            }
            await add(files, skipped: skipped)
        }
    }

    private func addBuildPhotos(_ files: [(URL, String?)]) {
        Task { await add(files, skipped: []) }
    }

    /// Copies photos chosen in the Photos picker, as their original files.
    private func importPicked(_ items: [PhotosPickerItem]) {
        Task {
            var files: [(URL, String?)] = []
            var failed = 0
            for item in items {
                if let picked = try? await item.loadTransferable(type: PickedPhoto.self) {
                    files.append((picked.url, picked.url.lastPathComponent))
                } else {
                    failed += 1
                }
            }
            await add(files, skipped: [], unreadable: failed)
            for file in files { try? FileManager.default.removeItem(at: file.0.deletingLastPathComponent()) }
        }
    }

    private func add(_ files: [(URL, String?)], skipped: [String], unreadable: Int = 0) async {
        let service = BuildPhotoService(context: modelContext, library: assetLibrary)
        let outcomes = await service.addPhotos(files.map { (url: $0.0, filename: $0.1) }, to: project)
        var failures = skipped.map { String(localized: "“\($0)” isn't a photo.") }
        if unreadable > 0 {
            failures.append(String(AttributedString(
                localized: "^[\(unreadable) photo](inflect: true) couldn't be read from Photos.").inflected().characters))
        }
        var duplicates: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .added: break
            case .duplicate(_, let filename): duplicates.append(filename)
            case .failed(_, let error): failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            photoReport = CaptureReport(
                title: failures.count == 1
                    ? String(localized: "A Photo Couldn't Be Added")
                    : String(localized: "\(failures.count) Photos Couldn't Be Added"),
                message: (failures + duplicates.map { String(localized: "“\($0)” is already in this project's build photos.") })
                    .joined(separator: "\n")
            )
        } else if !duplicates.isEmpty {
            photoReport = CaptureReport(
                title: String(localized: "Already in Build Photos"),
                message: duplicates.map { "“\($0)”" }.joined(separator: "\n")
            )
        }
    }

    /// Everything dropped or pasted becomes a Reference, so show all References.
    private func capture(_ providers: [NSItemProvider]) {
        section = .references
        referenceFilter = ReferenceFilter()
        captureCoordinator?.capture(providers, into: project)
    }
}

/// A photo from the Photos picker, copied as its original file into a
/// temporary folder of its own.
nonisolated struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "BenchBook-Picked-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: received.file.lastPathComponent, directoryHint: .notDirectory)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedPhoto(url: destination)
        }
    }
}

/// The project photo, small, in the window's title area. Opens it.
private struct ProjectPhotoButton: View {
    let photo: BuildPhoto
    let action: () -> Void

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Project photo. Click to open it.")
        .accessibilityLabel("Project photo")
        .task(id: photo.asset?.id) {
            if let thumbnailStore, let asset = photo.asset {
                thumbnail = await thumbnailStore.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            }
        }
    }
}

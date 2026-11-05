import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Adds or edits an aftermarket part. Nothing is saved until Save.
struct AftermarketEditorView: View {
    enum Request: Identifiable {
        case new(Project)
        case edit(AftermarketItem)

        var id: String {
            switch self {
            case .new(let project): "new-\(project.id.uuidString)"
            case .edit(let item): item.id.uuidString
            }
        }
    }

    /// What Save does to the picture.
    private enum ImageChange: Equatable {
        case unchanged
        case removed
        case file(URL)
    }

    let request: Request

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AftermarketDraft
    /// Set once a new item is first saved, so retrying after an error
    /// doesn't add it twice.
    @State private var savedItem: AftermarketItem?
    @State private var imageChange = ImageChange.unchanged
    @State private var preview: NSImage?
    @State private var isChoosingImage = false
    @State private var isFetchingImage = false
    @State private var isDropTargeted = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Dropped and downloaded pictures wait here until Save.
    @State private var workFolder = FileManager.default.temporaryDirectory
        .appending(path: "BenchBook-Aftermarket-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(request: Request) {
        self.request = request
        switch request {
        case .new(let project):
            _draft = State(initialValue: AftermarketDraft(project: project))
        case .edit(let item):
            _draft = State(initialValue: AftermarketDraft(item: item))
            _savedItem = State(initialValue: item)
        }
    }

    private var service: AftermarketService {
        AftermarketService(context: modelContext, library: assetLibrary)
    }

    private var isNew: Bool {
        if case .new = request { true } else { false }
    }

    private var hasImage: Bool {
        switch imageChange {
        case .unchanged: savedItem?.imageAsset != nil
        case .removed: false
        case .file: true
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.productName, prompt: Text("e.g. 50th Anniversary 2015"))
                TextField("Manufacturer", text: $draft.manufacturer, prompt: Text("e.g. Galaxy Models"))
                TextField("Product Number", text: $draft.productNumber, prompt: Text("Optional"))
                Picker("Type", selection: $draft.type) {
                    ForEach(AftermarketType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Picker("Status", selection: $draft.status) {
                    ForEach(AftermarketStatus.allCases) { status in
                        Label(status.displayName, systemImage: status.systemImage).tag(status)
                    }
                }
                TextField("Scale or Fits", text: $draft.scaleCompatibility, prompt: Text("e.g. 1:48, Tamiya F-16C"))
            }

            Section {
                TextField("Product Page", text: $draft.productURL, prompt: Text("https://…"))
                    .textContentType(.URL)
            } footer: {
                if !draft.hasValidURL {
                    Text("Enter a web address, such as hannants.co.uk/product/…")
                        .foregroundStyle(.red)
                }
            }

            Section("Picture") {
                imageWell
            }

            Section {
                TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle(isNew ? "New Part" : "Edit Part")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!draft.hasValidName || !draft.hasValidURL || isSaving || isFetchingImage)
            }
        }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { useImage(at: url) }
        }
        .task {
            if let asset = savedItem?.imageAsset {
                preview = await thumbnailStore?.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            }
        }
        .onDisappear {
            try? FileManager.default.removeItem(at: workFolder)
        }
        .alert(
            "Couldn't Save Part",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Picture

    private var imageWell: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.6))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Picture of the part")
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.title2)
                        Text("Drop an Image")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if isFetchingImage {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 140, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .onDrop(of: CaptureDrop.types, isTargeted: $isDropTargeted) { providers in
                receiveDrop(CaptureDrop.providers(fallback: providers))
                return true
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("Choose Image…") { isChoosingImage = true }
                Button("Use Image from Product Page", action: fetchPageImage)
                    .disabled(draft.parsedURL == nil || isFetchingImage)
                    .help(draft.parsedURL == nil
                          ? "Enter the product page first"
                          : "Download the picture the product page shows in link previews")
                if hasImage {
                    Button("Remove Image") {
                        imageChange = .removed
                        preview = nil
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func useImage(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = AftermarketError.notAnImage(url.lastPathComponent).localizedDescription
            return
        }
        preview = image
        imageChange = .file(url)
    }

    /// An image becomes the picture; a dropped link fills in the product
    /// page if it's empty.
    private func receiveDrop(_ providers: [NSItemProvider]) {
        let folder = workFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = await ItemProviderReader(fileDirectory: folder, copiesFileURLs: true).read(providers)
            for item in result.items {
                if case .file(let url, _, _) = item, ItemProviderReader.isReadableImage(url) {
                    useImage(at: url)
                    return
                }
            }
            for item in result.items {
                if case .link(let url, _) = item, draft.productURL.trimmedOrNil == nil {
                    draft.productURL = url.absoluteString
                    return
                }
            }
            errorMessage = String(localized: "Drop an image file, or an image from a web page.")
        }
    }

    private func fetchPageImage() {
        guard let page = draft.parsedURL else { return }
        isFetchingImage = true
        let folder = workFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        Task {
            defer { isFetchingImage = false }
            do {
                useImage(at: try await AftermarketService.downloadPageImage(from: page, into: folder))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Saving

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let item: AftermarketItem
                if let savedItem {
                    try service.update(savedItem, from: draft)
                    item = savedItem
                } else if case .new(let project) = request {
                    item = try service.create(in: project, from: draft)
                    savedItem = item
                } else {
                    return
                }
                switch imageChange {
                case .unchanged: break
                case .removed: try service.removeImage(from: item)
                case .file(let url): try await service.setImage(from: url, on: item)
                }
                imageChange = .unchanged
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// An aftermarket part's picture, or a box icon when it has none.
struct AftermarketThumbnail: View {
    let item: AftermarketItem
    var size: CGFloat = 36

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: item.imageAsset?.id) {
            if let asset = item.imageAsset {
                image = await thumbnailStore?.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            } else {
                image = nil
            }
        }
    }
}

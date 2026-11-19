import SwiftUI
import UniformTypeIdentifiers

/// What Save does to an editor's picture.
enum PictureChange: Equatable {
    case unchanged
    case removed
    case file(URL)
}

/// A picture drop target with Choose Image…, Use Image from Product Page and
/// Remove Image, as in the aftermarket and kit editors. Nothing is stored
/// until the editor saves `change`.
struct PictureWell: View {
    @Binding var change: PictureChange
    /// The picture shown: the stored one's thumbnail, or a new choice.
    @Binding var preview: NSImage?
    @Binding var isFetching: Bool
    /// Whether the record already has a stored picture.
    let hasStoredPicture: Bool
    /// The product page to fetch a picture from, if one is entered.
    let pageURL: URL?
    /// Where dropped and downloaded pictures wait until Save.
    let workFolder: URL
    /// e.g. "Picture of the part".
    let accessibilityLabel: LocalizedStringKey
    /// A dropped link, when no image came with it.
    let onLinkDropped: (URL) -> Bool
    let onError: (String) -> Void

    @State private var isChoosing = false
    @State private var isDropTargeted = false

    private var hasPicture: Bool {
        switch change {
        case .unchanged: hasStoredPicture
        case .removed: false
        case .file: true
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.6))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(Text(accessibilityLabel))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.title2)
                        Text("Drop an Image")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if isFetching {
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
                Button("Choose Image…") { isChoosing = true }
                Button("Use Image from Product Page", action: fetchPageImage)
                    .disabled(pageURL == nil || isFetching)
                    .help(pageURL == nil
                          ? "Enter the product page first"
                          : "Download the picture the product page shows in link previews")
                if hasPicture {
                    Button("Remove Image") {
                        change = .removed
                        preview = nil
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { useImage(at: url) }
        }
    }

    private func useImage(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else {
            onError(PictureImporter.PictureError.notAnImage(url.lastPathComponent).localizedDescription)
            return
        }
        preview = image
        change = .file(url)
    }

    /// An image becomes the picture; otherwise a dropped link is offered to
    /// the editor, e.g. to fill in the product page.
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
                if case .link(let url, _) = item, onLinkDropped(url) { return }
            }
            onError(String(localized: "Drop an image file, or an image from a web page."))
        }
    }

    private func fetchPageImage() {
        guard let page = pageURL else { return }
        isFetching = true
        let folder = workFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        Task {
            defer { isFetching = false }
            do {
                useImage(at: try await AftermarketService.downloadPageImage(from: page, into: folder))
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

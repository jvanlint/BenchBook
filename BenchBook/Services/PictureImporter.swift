import Foundation

/// Copies a picture the user chose, such as box art or a photo of a part,
/// into the library byte for byte, ready to attach to a record.
struct PictureImporter {
    let library: AssetLibrary

    enum PictureError: LocalizedError, Equatable {
        case notAnImage(String)

        var errorDescription: String? {
            switch self {
            case .notAnImage(let name): String(localized: "“\(name)” isn't an image BenchBook can use.")
            }
        }
    }

    /// Checks the file is an image and copies it into Originals. Returns the
    /// new asset, not yet inserted; if saving it fails, the caller removes
    /// its files with `AssetLibrary.removeFiles`.
    func importImage(from url: URL) async throws -> ManagedAsset {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let inspected = try await Task.detached(priority: .userInitiated) {
            try FileInspector.inspect(url)
        }.value
        guard inspected.kind == .image else { throw PictureError.notAnImage(url.lastPathComponent) }

        let assetID = UUID()
        let relativePath = AssetLibrary.originalRelativePath(assetID: assetID, fileExtension: inspected.fileExtension)
        let library = library
        try await Task.detached(priority: .userInitiated) {
            try library.copyOriginal(from: url, toRelativePath: relativePath)
        }.value

        return ManagedAsset(
            id: assetID,
            originalRelativePath: relativePath,
            originalFilename: url.lastPathComponent,
            mimeType: inspected.mimeType,
            byteCount: inspected.byteCount,
            sha256: inspected.sha256,
            pixelWidth: inspected.pixelWidth,
            pixelHeight: inspected.pixelHeight
        )
    }
}

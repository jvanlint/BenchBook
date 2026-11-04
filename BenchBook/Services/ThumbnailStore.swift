import AppKit
import Foundation
import QuickLookThumbnailing

/// Loads gallery thumbnails, generating them from originals when missing.
/// Thumbnails are derived data: if generation fails, the tile shows a type
/// icon and the original is untouched.
final class ThumbnailStore {
    static let pixelSize = CGSize(width: 480, height: 480)

    private let library: AssetLibrary
    private let cache = NSCache<NSUUID, NSImage>()
    private let posterCache = NSCache<NSString, NSImage>()

    init(library: AssetLibrary) {
        self.library = library
    }

    func thumbnail(assetID: UUID, originalRelativePath: String) async -> NSImage? {
        if let cached = cache.object(forKey: assetID as NSUUID) {
            return cached
        }
        let library = library
        let thumbnailURL = library.thumbnailURL(assetID: assetID)

        if let data = await Task.detached(operation: { try? Data(contentsOf: thumbnailURL) }).value,
           let image = NSImage(data: data) {
            cache.setObject(image, forKey: assetID as NSUUID)
            return image
        }

        let originalURL = library.url(forRelativePath: originalRelativePath)
        let request = QLThumbnailGenerator.Request(
            fileAt: originalURL,
            size: Self.pixelSize,
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let cgImage = representation.cgImage
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: assetID as NSUUID)

        await Task.detached {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: library.thumbnailsURL, withIntermediateDirectories: true)
            try? png.write(to: thumbnailURL, options: .atomic)
        }.value
        return image
    }

    /// A video link's poster, or nil if none has been fetched. `version`
    /// changes when the poster is refetched, so the cache doesn't go stale.
    func videoPoster(referenceID: UUID, version: Date?) async -> NSImage? {
        let key = "\(referenceID.uuidString)-\(version?.timeIntervalSinceReferenceDate ?? 0)" as NSString
        if let cached = posterCache.object(forKey: key) {
            return cached
        }
        let url = library.videoPosterURL(referenceID: referenceID)
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value,
              let image = NSImage(data: data)
        else { return nil }
        posterCache.setObject(image, forKey: key)
        return image
    }
}

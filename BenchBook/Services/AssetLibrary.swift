import Foundation

/// The app-managed folder of original files and derived thumbnails:
///
///     <root>/Originals/<asset-id>.<ext>   durable user data
///     <root>/Thumbnails/<asset-id>.png    replaceable, regenerated on demand
///     <root>/Posters/<reference-id>.jpg   video posters and webpage previews, re-fetchable
///
/// Records store paths relative to the root, never absolute paths.
nonisolated struct AssetLibrary: Sendable {
    let rootURL: URL

    var originalsURL: URL { rootURL.appending(path: "Originals", directoryHint: .isDirectory) }
    var thumbnailsURL: URL { rootURL.appending(path: "Thumbnails", directoryHint: .isDirectory) }
    var postersURL: URL { rootURL.appending(path: "Posters", directoryHint: .isDirectory) }

    static func originalRelativePath(assetID: UUID, fileExtension: String) -> String {
        "Originals/\(assetID.uuidString).\(fileExtension)"
    }

    func url(forRelativePath relativePath: String) -> URL {
        rootURL.appending(path: relativePath, directoryHint: .notDirectory)
    }

    func thumbnailURL(assetID: UUID) -> URL {
        thumbnailsURL.appending(path: "\(assetID.uuidString).png", directoryHint: .notDirectory)
    }

    /// A video poster or webpage preview, named by its Reference's id.
    func posterURL(referenceID: UUID) -> URL {
        postersURL.appending(path: "\(referenceID.uuidString).jpg", directoryHint: .notDirectory)
    }

    /// Posters whose Reference no longer exists.
    func orphanedPosters(knownReferenceIDs: Set<UUID>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: postersURL, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return true }
            return !knownReferenceIDs.contains(id)
        }
    }

    /// Copies the source byte-for-byte. The file appears at its final path
    /// only once fully written.
    func copyOriginal(from source: URL, toRelativePath relativePath: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: originalsURL, withIntermediateDirectories: true)

        let destination = url(forRelativePath: relativePath)
        let partial = originalsURL.appending(path: ".partial-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try fileManager.copyItem(at: source, to: partial)
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// Removes an original and its thumbnail. Missing files are not an error.
    func removeFiles(assetID: UUID, originalRelativePath: String) {
        try? FileManager.default.removeItem(at: url(forRelativePath: originalRelativePath))
        try? FileManager.default.removeItem(at: thumbnailURL(assetID: assetID))
    }

    /// Files in Originals and Thumbnails whose asset ID isn't in `knownAssetIDs`,
    /// plus leftover partial copies. Used to clean up after interrupted imports.
    func orphanedFiles(knownAssetIDs: Set<UUID>) -> [URL] {
        let fileManager = FileManager.default
        var orphans: [URL] = []
        for folder in [originalsURL, thumbnailsURL] {
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            for file in contents {
                let name = file.deletingPathExtension().lastPathComponent
                if name.hasPrefix(".partial-") {
                    orphans.append(file)
                } else if let id = UUID(uuidString: name), !knownAssetIDs.contains(id) {
                    orphans.append(file)
                }
            }
        }
        return orphans
    }
}

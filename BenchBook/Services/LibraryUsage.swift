import Foundation

/// Disk space used by the file library, by folder.
nonisolated struct LibraryUsage: Equatable, Sendable {
    var originals: Int64 = 0
    var thumbnails: Int64 = 0
    var posters: Int64 = 0

    var total: Int64 { originals + thumbnails + posters }

    /// Reads file sizes, so call it off the main actor.
    static func measure(_ library: AssetLibrary) -> LibraryUsage {
        LibraryUsage(
            originals: size(of: library.originalsURL),
            thumbnails: size(of: library.thumbnailsURL),
            posters: size(of: library.postersURL)
        )
    }

    /// Space the folder's files take on disk. Zero if it doesn't exist.
    static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

import CoreData
import Foundation
import SwiftData

/// Before SwiftData upgrades a library to a new schema, its database is
/// copied next to it, e.g. "BenchBook Before 4.0.0.store", so the library
/// can be put back by hand if the upgrade goes wrong. Files in Library/
/// aren't copied: upgrades don't touch them.
nonisolated enum LibraryUpgradeCopy {
    enum CopyError: LocalizedError {
        case failed(underlying: Error)

        var errorDescription: String? {
            String(localized: "BenchBook couldn't make a copy of your library before upgrading it, so it hasn't been upgraded.")
        }

        var failureReason: String? {
            if case .failed(let error) = self { error.localizedDescription } else { nil }
        }
    }

    /// The store's companion files, which hold changes not yet written into it.
    private static let suffixes = ["", "-wal", "-shm"]

    /// True when a store exists at `storeURL` and isn't already in `schema`.
    static func needsUpgrade(storeURL: URL, models: [any PersistentModel.Type]) throws -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: models) else { return false }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// Where the copy for `version` goes, e.g. "BenchBook Before 4.0.0.store".
    static func copyURL(for storeURL: URL, version: Schema.Version) -> URL {
        let name = storeURL.deletingPathExtension().lastPathComponent
        return storeURL.deletingLastPathComponent()
            .appending(path: "\(name) Before \(version.major).\(version.minor).\(version.patch).\(storeURL.pathExtension)")
    }

    /// Copies the store if it needs upgrading. An existing copy is kept, as
    /// it's from before the first try. Returns the copy, or nil if none was
    /// needed. Throws if the copy can't be made, so the upgrade doesn't run.
    @discardableResult
    static func makeIfNeeded(storeURL: URL, models: [any PersistentModel.Type], version: Schema.Version) throws -> URL? {
        do {
            guard try needsUpgrade(storeURL: storeURL, models: models) else { return nil }
            let copy = copyURL(for: storeURL, version: version)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: copy.path) { return copy }

            // Copy into a folder first, so a failed copy never leaves part of one.
            let staging = storeURL.deletingLastPathComponent()
                .appending(path: ".BenchBook-UpgradeCopy-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: staging) }

            var staged: [(URL, URL)] = []
            for suffix in suffixes {
                let source = URL(filePath: storeURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let temporary = staging.appending(path: source.lastPathComponent)
                try fileManager.copyItem(at: source, to: temporary)
                staged.append((temporary, URL(filePath: copy.path + suffix)))
            }
            // The companion files go first, so the copy is only there once complete.
            for (temporary, destination) in staged.reversed() {
                // Left by an earlier copy that failed: without the store, it's no copy.
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return copy
        } catch {
            throw CopyError.failed(underlying: error)
        }
    }
}

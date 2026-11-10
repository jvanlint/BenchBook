import AppleArchive
import CryptoKit
import Foundation
import SQLite3
import System
import UniformTypeIdentifiers

extension UTType {
    /// A .benchbookbackup file: one Apple Archive holding a library.
    nonisolated static let benchBookBackup = UTType(exportedAs: "com.jasonvanlint.benchbook.backup")
}

/// Where a library lives: the SwiftData store and the folder of files beside it.
nonisolated struct LibraryLocation: Sendable {
    /// e.g. …/Application Support/BenchBook.store, with -wal and -shm files beside it.
    let storeURL: URL
    /// e.g. …/Application Support/Library, holding Originals, Thumbnails and Posters.
    let libraryURL: URL

    /// The store and the files SQLite keeps beside it.
    var storeFiles: [URL] {
        LibraryBackup.storeSuffixes.map { URL(fileURLWithPath: storeURL.path + $0) }
    }
}

/// What a backup holds, saved inside it as manifest.json.
nonisolated struct BackupManifest: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var projects = 0
        var references = 0
        var paints = 0
    }

    /// A file in the backup, relative to its root, e.g. "Library/Originals/<id>.jpg".
    struct File: Codable, Equatable, Sendable {
        var path: String
        var size: Int64
        var sha256: String
    }

    static let currentFormat = 1

    var format = currentFormat
    var createdAt: Date
    /// The BenchBook version that made it, e.g. "1.1.0".
    var appVersion: String
    var schemaVersion: String
    var counts: Counts
    var files: [File]

    /// Size of the files, store included.
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

nonisolated enum LibraryBackupError: LocalizedError, Equatable {
    case snapshotFailed(String)
    case archiveFailed
    case notABackup
    case newerFormat
    case damaged(String)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let detail):
            String(localized: "BenchBook couldn't copy its database (\(detail)).")
        case .archiveFailed:
            String(localized: "The backup file couldn't be written. Check there's enough space where you're saving it.")
        case .notABackup:
            String(localized: "This isn't a BenchBook backup, or it's damaged.")
        case .newerFormat:
            String(localized: "This backup was made by a newer version of BenchBook. Update BenchBook, then restore it.")
        case .damaged(let path):
            String(localized: "This backup is damaged: “\(path)” doesn't match what was backed up. Your library hasn't been changed.")
        }
    }
}

/// Backs up a library to one file and unpacks and checks a backup, off the
/// main thread. Only the database, original files and posters are kept;
/// thumbnails are made again when shown.
nonisolated enum LibraryBackup {
    static let manifestName = "manifest.json"
    static let storeName = "BenchBook.store"
    static let libraryFolderName = "Library"
    /// Posters are kept because they can only be fetched again from the web.
    static let folders = ["Originals", "Posters"]
    static let storeSuffixes = ["", "-wal", "-shm"]

    // MARK: Back up

    /// Writes a backup of `location` to `destination`. `counts` describes
    /// the library for the restore summary.
    @discardableResult
    static func backUp(
        _ location: LibraryLocation,
        to destination: URL,
        appVersion: String,
        schemaVersion: String,
        counts: BackupManifest.Counts,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> BackupManifest {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "BenchBook Backup \(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // Files, then the database, then files added meanwhile, so every file
        // the database names is in the backup. Copies are clones on APFS.
        let stagedLibrary = staging.appending(path: libraryFolderName, directoryHint: .isDirectory)
        try copyFolders(from: location.libraryURL, to: stagedLibrary)
        try snapshotStore(at: location.storeURL, to: staging.appending(path: storeName))
        try copyFolders(from: location.libraryURL, to: stagedLibrary)
        progress(0.1)

        let paths = try relativeFilePaths(in: staging)
        var files: [BackupManifest.File] = []
        for (index, path) in paths.enumerated() {
            let url = staging.appending(path: path)
            files.append(BackupManifest.File(path: path, size: try fileSize(url), sha256: try sha256(of: url)))
            progress(0.1 + 0.4 * Double(index + 1) / Double(max(paths.count, 1)))
        }
        let manifest = BackupManifest(
            createdAt: .now, appVersion: appVersion, schemaVersion: schemaVersion, counts: counts, files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appending(path: manifestName))

        do {
            try writeArchive(of: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        progress(1)
        return manifest
    }

    /// A consistent copy of the database even while the app has it open,
    /// including changes still in its write-ahead log.
    static func snapshotStore(at storeURL: URL, to destination: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(database)
            throw LibraryBackupError.snapshotFailed(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 10_000)
        let quoted = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(database, "VACUUM INTO '\(quoted)'", nil, nil, nil) == SQLITE_OK else {
            throw LibraryBackupError.snapshotFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Copies the backed-up folders' files that aren't in `destination` yet.
    private static func copyFolders(from library: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        for folder in folders {
            let source = library.appending(path: folder, directoryHint: .isDirectory)
            let target = destination.appending(path: folder, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            for path in try relativeFilePaths(in: source) {
                // Imports in progress write a hidden partial file first.
                guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                let copy = target.appending(path: path)
                guard !fileManager.fileExists(atPath: copy.path) else { continue }
                try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fileManager.copyItem(at: source.appending(path: path), to: copy)
                } catch CocoaError.fileReadNoSuchFile {
                    // Deleted while backing up.
                }
            }
        }
    }

    /// Internal for tests.
    static func writeArchive(of folder: URL, to destination: URL) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(destination.path), mode: .writeOnly, options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw LibraryBackupError.archiveFailed }
        defer { try? file.close() }
        guard let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file) else {
            throw LibraryBackupError.archiveFailed
        }
        defer { try? compressed.close() }
        guard let encoder = ArchiveStream.encodeStream(writingTo: compressed),
              let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")
        else { throw LibraryBackupError.archiveFailed }
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path), keySet: keys)
            try encoder.close()
        } catch {
            throw LibraryBackupError.archiveFailed
        }
    }

    // MARK: Restore

    /// Unpacks a backup into the empty folder `staging` and checks every
    /// file against its manifest. Throws if anything is missing, extra or changed.
    static func unpack(_ archive: URL, into staging: URL) throws -> BackupManifest {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try extractArchive(archive, to: staging)

        let manifestURL = staging.appending(path: manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else { throw LibraryBackupError.notABackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A newer format may not decode, so check the number on its own first.
        struct Format: Decodable { var format: Int }
        guard let format = try? decoder.decode(Format.self, from: data) else { throw LibraryBackupError.notABackup }
        guard format.format <= BackupManifest.currentFormat else { throw LibraryBackupError.newerFormat }
        guard let manifest = try? decoder.decode(BackupManifest.self, from: data) else { throw LibraryBackupError.notABackup }
        guard manifest.files.contains(where: { $0.path == storeName }) else { throw LibraryBackupError.notABackup }

        let expected = Set(manifest.files.map(\.path))
        let found = try relativeFilePaths(in: staging).filter { $0 != manifestName }
        if let extra = found.first(where: { !expected.contains($0) }) { throw LibraryBackupError.damaged(extra) }
        for file in manifest.files {
            let url = staging.appending(path: file.path)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? fileSize(url)) == file.size,
                  (try? sha256(of: url)) == file.sha256
            else { throw LibraryBackupError.damaged(file.path) }
        }
        return manifest
    }

    /// Extracts only plain files and folders inside `folder`: no links, and
    /// no paths that climb out of it.
    private static func extractArchive(_ archive: URL, to folder: URL) throws {
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw LibraryBackupError.notABackup }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
            throw LibraryBackupError.notABackup
        }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw LibraryBackupError.notABackup }
        defer { try? decoder.close() }

        var rejected = false
        let filter: ArchiveHeader.EntryFilter = { message, path, data in
            guard message == .extractBegin else { return .ok }
            let isSafePath = !path.isAbsolute && !path.components.contains { $0.string == ".." }
            let isPlain: Bool
            if case .header(let header) = data {
                isPlain = header.entryType == .regularFile || header.entryType == .directory
            } else {
                isPlain = false
            }
            guard isSafePath, isPlain else {
                rejected = true
                return .skip
            }
            return .ok
        }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), selectUsing: filter) else {
            throw LibraryBackupError.notABackup
        }
        defer { try? extractor.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
        } catch {
            throw LibraryBackupError.notABackup
        }
        if rejected { throw LibraryBackupError.notABackup }
    }

    /// Moves the current library into `previous` and the unpacked backup in
    /// `staging` into its place. If any step fails, every move is undone.
    static func swap(_ location: LibraryLocation, withUnpacked staging: URL, keepingCurrentIn previous: URL) throws {
        let fileManager = FileManager.default
        enum Step {
            case moved(from: URL, to: URL)
            case created(URL)
        }
        var steps: [Step] = []
        func move(_ source: URL, to destination: URL) throws {
            try fileManager.moveItem(at: source, to: destination)
            steps.append(.moved(from: source, to: destination))
        }

        do {
            try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
            // The current library, aside.
            for file in location.storeFiles where fileManager.fileExists(atPath: file.path) {
                try move(file, to: previous.appending(path: file.lastPathComponent))
            }
            if fileManager.fileExists(atPath: location.libraryURL.path) {
                try move(location.libraryURL, to: previous.appending(path: location.libraryURL.lastPathComponent, directoryHint: .isDirectory))
            }
            // The backup, in. Opening it to check it may have left -wal and -shm files.
            for (suffix, target) in zip(storeSuffixes, location.storeFiles) {
                let staged = staging.appending(path: storeName + suffix)
                if fileManager.fileExists(atPath: staged.path) { try move(staged, to: target) }
            }
            try fileManager.createDirectory(at: location.libraryURL, withIntermediateDirectories: true)
            steps.append(.created(location.libraryURL))
            let stagedLibrary = staging.appending(path: libraryFolderName, directoryHint: .isDirectory)
            for folder in folders {
                let staged = stagedLibrary.appending(path: folder, directoryHint: .isDirectory)
                if fileManager.fileExists(atPath: staged.path) {
                    try move(staged, to: location.libraryURL.appending(path: folder, directoryHint: .isDirectory))
                }
            }
        } catch {
            for step in steps.reversed() {
                switch step {
                case .moved(let source, let destination): try? fileManager.moveItem(at: destination, to: source)
                case .created(let folder): try? fileManager.removeItem(at: folder)
                }
            }
            throw error
        }
    }

    // MARK: Files

    /// Every regular file under `folder`, as paths relative to it.
    static func relativeFilePaths(in folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            paths.append(String(path.dropFirst(base.count + 1)))
        }
        return paths.sorted()
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

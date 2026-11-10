import Foundation
import SwiftData
import Testing
@testable import BenchBook

/// Backups of an on-disk library, made while it's open as in the app.
@MainActor
struct LibraryBackupTests {
    let folder: TemporaryFolder
    let location: LibraryLocation

    init() throws {
        folder = try TemporaryFolder()
        location = LibraryLocation(
            storeURL: folder.url.appending(path: "BenchBook.store"),
            libraryURL: folder.url.appending(path: "Library", directoryHint: .isDirectory)
        )
    }

    private var backupURL: URL { folder.file("Test.benchbookbackup") }
    private var stagingURL: URL { folder.url.appending(path: "Staging", directoryHint: .isDirectory) }
    private var previousURL: URL { folder.url.appending(path: "Before Restore", directoryHint: .isDirectory) }

    private func openContainer() throws -> ModelContainer {
        try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: location.storeURL)
        )
    }

    /// A project with one imported image and a poster file. Returns the
    /// original's library path and bytes, and the poster's bytes.
    private func fillLibrary(_ container: ModelContainer) async throws -> (originalPath: String, original: Data, poster: Data) {
        let context = container.mainContext
        let library = AssetLibrary(rootURL: location.libraryURL)
        let project = Fixtures.makeProject("F-16C", in: context)
        let source = try Fixtures.writePNG(to: folder.file("intake.png"), width: 30, height: 20)
        let outcomes = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: source, originalFilename: "intake.png", resourceURL: nil)], into: project, tags: [])
        guard case .added(let reference) = try #require(outcomes.first), let asset = reference.asset else {
            throw CocoaError(.fileReadUnknown)
        }
        reference.title = "Intake"
        try context.save()

        let poster = Data("poster bytes".utf8)
        try FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try poster.write(to: library.posterURL(referenceID: reference.id))
        let original = try Data(contentsOf: library.url(forRelativePath: asset.originalRelativePath))
        return (asset.originalRelativePath, original, poster)
    }

    private func backUp() throws -> BackupManifest {
        try LibraryBackup.backUp(
            location, to: backupURL, appVersion: "1.0.1", schemaVersion: "10.0.0",
            counts: BackupManifest.Counts(projects: 1, references: 1, paints: 0)
        )
    }

    @Test func restoreBringsBackEveryRecordAndFile() async throws {
        let saved: (originalPath: String, original: Data, poster: Data)
        do {
            let container = try openContainer()
            saved = try await fillLibrary(container)

            // Backed up while the library is open.
            let manifest = try backUp()
            #expect(manifest.files.map(\.path).contains(LibraryBackup.storeName))
            #expect(manifest.files.map(\.path).contains("Library/" + saved.originalPath))
            #expect(!manifest.files.contains { $0.path.contains("Thumbnails") })

            // Changes after the backup, which the restore undoes.
            _ = Fixtures.makeProject("Later Build", in: container.mainContext)
            try FileManager.default.removeItem(at: location.libraryURL.appending(path: saved.originalPath))
        }

        let manifest = try LibraryBackup.unpack(backupURL, into: stagingURL)
        #expect(manifest.counts.projects == 1)
        try LibraryBackup.swap(location, withUnpacked: stagingURL, keepingCurrentIn: previousURL)

        let container = try openContainer()
        let context = container.mainContext
        #expect(try context.fetch(FetchDescriptor<Project>()).map(\.name) == ["F-16C"])
        let reference = try #require(try context.fetch(FetchDescriptor<Reference>()).first)
        #expect(reference.title == "Intake")
        #expect(reference.asset?.originalRelativePath == saved.originalPath)
        // Byte for byte.
        #expect(try Data(contentsOf: location.libraryURL.appending(path: saved.originalPath)) == saved.original)
        #expect(try Data(contentsOf: AssetLibrary(rootURL: location.libraryURL).posterURL(referenceID: reference.id)) == saved.poster)

        // The library from before the restore is kept whole.
        #expect(FileManager.default.fileExists(atPath: previousURL.appending(path: "BenchBook.store").path))
        let previous = try PersistenceController.makeContainer(configuration: ModelConfiguration(
            schema: PersistenceController.schema, url: previousURL.appending(path: "BenchBook.store")
        ))
        #expect(Set(try previous.mainContext.fetch(FetchDescriptor<Project>()).map(\.name)) == ["F-16C", "Later Build"])
    }

    @Test func changedOrExtraFilesAreRejected() async throws {
        do {
            let container = try openContainer()
            _ = try await fillLibrary(container)
            _ = try backUp()
        }
        let changedBackup = folder.file("Changed.benchbookbackup")
        let extraBackup = folder.file("Extra.benchbookbackup")

        // One changed byte in an original.
        let changed = folder.url.appending(path: "Changed", directoryHint: .isDirectory)
        let manifest = try LibraryBackup.unpack(backupURL, into: changed)
        let original = try #require(manifest.files.first { $0.path.hasPrefix("Library/Originals/") })
        let originalURL = changed.appending(path: original.path)
        var bytes = try Data(contentsOf: originalURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: originalURL)
        try LibraryBackup.writeArchive(of: changed, to: changedBackup)
        #expect(throws: LibraryBackupError.damaged(original.path)) {
            try LibraryBackup.unpack(changedBackup, into: folder.url.appending(path: "Check1", directoryHint: .isDirectory))
        }

        // A file the manifest doesn't list.
        let extra = folder.url.appending(path: "Extra", directoryHint: .isDirectory)
        _ = try LibraryBackup.unpack(backupURL, into: extra)
        try Data("surprise".utf8).write(to: extra.appending(path: "Library/Originals/extra.txt"))
        try LibraryBackup.writeArchive(of: extra, to: extraBackup)
        #expect(throws: LibraryBackupError.damaged("Library/Originals/extra.txt")) {
            try LibraryBackup.unpack(extraBackup, into: folder.url.appending(path: "Check2", directoryHint: .isDirectory))
        }
    }

    @Test func otherFilesAndNewerFormatsAreRefused() throws {
        // Not an archive at all.
        try Data("hello".utf8).write(to: backupURL)
        #expect(throws: LibraryBackupError.notABackup) {
            try LibraryBackup.unpack(backupURL, into: stagingURL)
        }

        // A backup from a future BenchBook.
        let future = folder.url.appending(path: "Future", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
        try Data(#"{"format": 99}"#.utf8).write(to: future.appending(path: LibraryBackup.manifestName))
        try LibraryBackup.writeArchive(of: future, to: backupURL)
        #expect(throws: LibraryBackupError.newerFormat) {
            try LibraryBackup.unpack(backupURL, into: folder.url.appending(path: "Check", directoryHint: .isDirectory))
        }
    }

    @Test func linksInABackupAreRefused() throws {
        let linked = folder.url.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linked.appending(path: "Library"), withDestinationURL: URL(fileURLWithPath: NSHomeDirectory())
        )
        try LibraryBackup.writeArchive(of: linked, to: backupURL)
        #expect(throws: LibraryBackupError.notABackup) {
            try LibraryBackup.unpack(backupURL, into: stagingURL)
        }
    }

    @Test func aFailedSwapLeavesTheLibraryAsItWas() async throws {
        let saved: (originalPath: String, original: Data, poster: Data)
        do {
            let container = try openContainer()
            saved = try await fillLibrary(container)
            _ = try backUp()
            _ = Fixtures.makeProject("Later Build", in: container.mainContext)
        }
        _ = try LibraryBackup.unpack(backupURL, into: stagingURL)

        // The unpacked library's folder can't be emptied, so the swap fails partway.
        let stagedLibrary = stagingURL.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stagedLibrary.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedLibrary.path) }
        #expect(throws: (any Error).self) {
            try LibraryBackup.swap(location, withUnpacked: stagingURL, keepingCurrentIn: previousURL)
        }

        // Everything is back where it was, with the changes made after the backup.
        let container = try openContainer()
        #expect(Set(try container.mainContext.fetch(FetchDescriptor<Project>()).map(\.name)) == ["F-16C", "Later Build"])
        #expect(try Data(contentsOf: location.libraryURL.appending(path: saved.originalPath)) == saved.original)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: previousURL.path))?.isEmpty ?? true)
    }

    @Test func previousLibrariesAreListedNewestFirst() throws {
        let older = LibraryRestore.previousLibraryURL(for: location, on: Date(timeIntervalSince1970: 1_000_000))
        let newer = LibraryRestore.previousLibraryURL(for: location, on: Date(timeIntervalSince1970: 2_000_000))
        for url in [older, newer] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        #expect(older.lastPathComponent.hasPrefix("BenchBook Before Restore "))
        #expect(LibraryRestore.previousLibraries(for: location) == [newer, older])
    }
}

import AppKit
import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ReferenceImportTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var importer: ReferenceImporter { ReferenceImporter(context: context, library: library) }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func originals() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: library.originalsURL, includingPropertiesForKeys: nil)) ?? []
    }

    @Test func importsFileAsByteIdenticalOriginalWithTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try Fixtures.writePNG(to: folder.file("wheel-well.png"))

        let outcomes = await importer.importItems(
            [.file(url: source, originalFilename: "wheel-well.png", resourceURL: URL(string: "https://example.com/a.png"))],
            into: project, tags: ["Wheel Well", "cockpit"], note: "  Port side  "
        )

        guard case .added(let reference) = try #require(outcomes.first) else {
            Issue.record("Expected .added, got \(outcomes)")
            return
        }
        let asset = try #require(reference.asset)
        #expect(reference.kind == .image)
        #expect(reference.note == "Port side")
        #expect(reference.originalResourceURL?.absoluteString == "https://example.com/a.png")
        #expect(asset.originalFilename == "wheel-well.png")
        #expect(asset.originalRelativePath == "Originals/\(asset.id.uuidString).png")
        #expect(reference.tags.map(\.name) == ["cockpit", "Wheel Well"])

        let stored = library.url(forRelativePath: asset.originalRelativePath)
        #expect(try Data(contentsOf: stored) == Data(contentsOf: source))

        // Removing the source must not affect the saved copy.
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: stored.path))
    }

    @Test func reusesTagsCaseInsensitively() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        _ = await importer.importItems([.text("one", sourceURL: nil, title: nil)], into: project, tags: ["Wheel Well"])
        _ = await importer.importItems([.text("two", sourceURL: nil, title: nil)], into: project, tags: ["wheel  well"])

        let tags = try context.fetch(FetchDescriptor<BenchBook.Tag>())
        #expect(tags.count == 1)
        #expect(tags.first?.name == "Wheel Well")
        #expect(tags.first?.referenceLinks.count == 2)
    }

    @Test func reportsDuplicateFileInSameProjectOnly() async throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let other = Fixtures.makeProject("Spitfire", in: context)
        let source = try Fixtures.writePNG(to: folder.file("a.png"))
        let copy = folder.file("copy.png")
        try FileManager.default.copyItem(at: source, to: copy)

        _ = await importer.importItems([.file(url: source, originalFilename: nil, resourceURL: nil)], into: f16)
        let again = await importer.importItems([.file(url: copy, originalFilename: nil, resourceURL: nil)], into: f16)
        let elsewhere = await importer.importItems([.file(url: copy, originalFilename: nil, resourceURL: nil)], into: other)

        guard case .duplicate = try #require(again.first) else {
            Issue.record("Expected .duplicate, got \(again)")
            return
        }
        guard case .added = try #require(elsewhere.first) else {
            Issue.record("Expected .added in another project, got \(elsewhere)")
            return
        }
        #expect(f16.references.count == 1)
        #expect(originals().count == 2)
    }

    @Test func importsLinksAndText() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let outcomes = await importer.importItems([
            .link(url: URL(string: "https://www.youtube.com/watch?v=abc123&t=1m30s")!, title: "Wheel well walkaround"),
            .link(url: URL(string: "https://example.com/f16")!, title: nil),
            .text("  The main gear bay is white.  ", sourceURL: URL(string: "https://example.com/f16"), title: "F-16 page"),
            .text("   ", sourceURL: nil, title: nil),
            .link(url: URL(string: "file:///etc/hosts")!, title: nil),
        ], into: project)

        #expect(outcomes.filter { if case .added = $0 { true } else { false } }.count == 3)
        #expect(outcomes.filter { if case .failed = $0 { true } else { false } }.count == 2)

        let byKind = Dictionary(grouping: project.references, by: \.kindRaw)
        let video = try #require(byKind["videoLink"]?.first)
        #expect(video.title == "Wheel well walkaround")
        #expect(video.sourcePageURL?.absoluteString == "https://www.youtube.com/watch?v=abc123&t=1m30s")
        #expect(video.videoMoments.map(\.offsetSeconds) == [90])

        #expect(byKind["webpage"]?.first?.sourcePageURL?.host() == "example.com")
        let snippet = try #require(byKind["textSnippet"]?.first)
        #expect(snippet.text == "The main gear bay is white.")
        #expect(snippet.sourcePageURL?.host() == "example.com")
        #expect(snippet.asset == nil)
    }

    @Test func failedFileLeavesNoRecordsOrFiles() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let unsupported = try Fixtures.writeText("hello", to: folder.file("notes.txt"))

        let outcomes = await importer.importItems([.file(url: unsupported, originalFilename: nil, resourceURL: nil)], into: project)

        guard case .failed(_, let error) = try #require(outcomes.first) else {
            Issue.record("Expected .failed")
            return
        }
        #expect(error as? CaptureError == .unsupportedFile("notes.txt"))
        #expect(project.references.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
        #expect(originals().isEmpty)
    }

    @Test func deletingReferenceRemovesItsUnusedFile() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try Fixtures.writePDF(to: folder.file("manual.pdf"))
        let outcomes = await importer.importItems([.file(url: source, originalFilename: nil, resourceURL: nil)], into: project)
        guard case .added(let reference) = try #require(outcomes.first) else {
            Issue.record("Expected .added")
            return
        }
        _ = await importer.importItems([.text("x", sourceURL: nil, title: nil)], into: project, tags: ["manual"])
        let assetID = try #require(reference.asset?.id)
        try FileManager.default.createDirectory(at: library.thumbnailsURL, withIntermediateDirectories: true)
        try Data("thumb".utf8).write(to: library.thumbnailURL(assetID: assetID))

        try ReferenceService(context: context, library: library).delete(reference)

        #expect(project.references.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
        #expect(originals().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.thumbnailURL(assetID: assetID).path))
        #expect(try context.fetchCount(FetchDescriptor<BenchBook.Tag>()) == 1)
    }

    @Test func reconcileRemovesOrphanedFilesOnly() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try Fixtures.writePNG(to: folder.file("keep.png"))
        _ = await importer.importItems([.file(url: source, originalFilename: nil, resourceURL: nil)], into: project)
        let orphan = library.originalsURL.appending(path: "\(UUID().uuidString).jpg")
        let partial = library.originalsURL.appending(path: ".partial-\(UUID().uuidString)")
        let unrelated = library.originalsURL.appending(path: "README.txt")
        for url in [orphan, partial, unrelated] {
            try Data("x".utf8).write(to: url)
        }

        try ReferenceService(context: context, library: library).reconcileLibrary()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(originals().count == 2)  // the kept original and README.txt
    }

    @Test func editingDetailsUpdatesTitleNoteAndTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let outcomes = await importer.importItems([.text("x", sourceURL: nil, title: nil)], into: project, tags: ["a", "b"])
        guard case .added(let reference) = try #require(outcomes.first) else { return }

        try ReferenceService(context: context, library: library)
            .updateDetails(reference, title: " Bay ", note: "", tagsText: "b, C")

        #expect(reference.title == "Bay")
        #expect(reference.note == nil)
        #expect(reference.tags.map(\.name) == ["b", "C"])
    }
}

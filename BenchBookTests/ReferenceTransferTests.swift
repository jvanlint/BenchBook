import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ReferenceTransferTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var transfer: ReferenceTransfer { ReferenceTransfer(context: context, library: library) }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func importImage(_ name: String, into project: Project, red: CGFloat = 1) async throws -> Reference {
        let file = try Fixtures.writePNG(to: folder.file("\(name).png"), width: 40, height: 30, red: red)
        let outcomes = await ReferenceImporter(context: context, library: library).importItems(
            [.file(url: file, originalFilename: "\(name).png", resourceURL: nil)], into: project, tags: ["Cockpit"]
        )
        guard case .added(let reference) = try #require(outcomes.first) else {
            throw CocoaError(.fileReadUnknown)
        }
        return reference
    }

    private func originals() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.originalsURL.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    @Test func movesReferencesWithEverythingOnThem() async throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let image = try await importImage("intake", into: f16)
        try ImageNoteService(context: context).addNote(
            to: image, pixelRect: CGRect(x: 2, y: 2, width: 20, height: 20), imageSize: CGSize(width: 40, height: 30)
        )
        let note = try ReferenceService(context: context, library: library)
            .createNote(in: f16, title: "Wheel wells", text: "Silver", tagsText: "")

        let result = try transfer.transfer([image, note], to: spitfire, mode: .move)

        #expect(result.transferred.map(\.id) == [image.id, note.id])
        #expect(f16.references.isEmpty)
        #expect(Set(spitfire.references.map(\.id)) == [image.id, note.id])
        #expect(image.markups.count == 1)
        #expect(image.tags.map(\.name) == ["Cockpit"])
        #expect(try context.fetchCount(FetchDescriptor<Reference>()) == 2)
        #expect(!context.hasChanges)
    }

    @Test func copiesShareTheFileAndKeepNotesTagsAndMoments() async throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let image = try await importImage("intake", into: f16)
        try ImageNoteService(context: context).addNote(
            to: image, pixelRect: CGRect(x: 2, y: 2, width: 20, height: 20), imageSize: CGSize(width: 40, height: 30)
        )
        let video = Reference(project: f16, kind: .videoLink, title: "Weathering",
                              sourcePageURL: URL(string: "https://www.youtube.com/watch?v=abc")!)
        video.videoChannel = "Night Shift"
        context.insert(video)
        context.insert(VideoMoment(reference: video, offsetSeconds: 90, title: "Oil dots"))
        try context.save()
        try FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try Data("poster".utf8).write(to: library.posterURL(referenceID: video.id))

        let result = try transfer.transfer([image, video], to: spitfire, mode: .copy)
        let copies = result.transferred
        #expect(copies.count == 2)
        #expect(f16.references.count == 2)
        #expect(spitfire.references.count == 2)

        let imageCopy = try #require(copies.first { $0.kind == .image })
        #expect(imageCopy.id != image.id)
        #expect(imageCopy.asset?.id == image.asset?.id)
        #expect(imageCopy.markups.count == 1)
        #expect(imageCopy.tags.map(\.name) == ["Cockpit"])
        #expect(originals().count == 1)

        let videoCopy = try #require(copies.first { $0.kind == .videoLink })
        #expect(videoCopy.videoChannel == "Night Shift")
        #expect(videoCopy.sortedVideoMoments.map(\.title) == ["Oil dots"])
        #expect(FileManager.default.fileExists(atPath: library.posterURL(referenceID: videoCopy.id).path))

        // The shared file stays until the last reference using it goes.
        let references = ReferenceService(context: context, library: library)
        try references.delete(image)
        #expect(originals().count == 1)
        try references.delete(imageCopy)
        #expect(originals().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
    }

    @Test func leavesFilesTheTargetAlreadyHas() async throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let image = try await importImage("intake", into: f16)
        let other = try await importImage("seat", into: f16, red: 0.2)
        _ = try await importImage("intake-again", into: spitfire)  // same pixels as "intake"

        let result = try transfer.transfer([image, other], to: spitfire, mode: .move)

        #expect(result.duplicates.map(\.id) == [image.id])
        #expect(result.transferred.map(\.id) == [other.id])
        #expect(image.project?.id == f16.id)
        #expect(spitfire.references.count == 2)

        // Nothing to do for references already in the target.
        let none = try transfer.transfer([other], to: spitfire, mode: .copy)
        #expect(none == ReferenceTransfer.Result())
    }

    @Test func noticesNameWhatHappened() async throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let note = try ReferenceService(context: context, library: library)
            .createNote(in: f16, title: "Wheel wells", text: "", tagsText: "")

        let moved = ReferenceTransferNotice(
            result: .init(transferred: [note]), mode: .move, project: spitfire
        )
        #expect(moved.message == "Moved “Wheel wells” to Spitfire.")
        #expect(moved.projectID == spitfire.id)
        let copied = ReferenceTransferNotice(
            result: .init(transferred: [note, note], duplicates: [note]), mode: .copy, project: spitfire
        )
        #expect(copied.message == "Copied 2 references to Spitfire. Spitfire already has “Wheel wells”, so it was left as it is.")
    }
}

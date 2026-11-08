import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ProjectDeletionTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func files(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// A project with an image (and a note on it), a text note, a video link
    /// poster, a paint list and an aftermarket part with a picture.
    private func makeFilledProject(_ name: String, paint: Paint) async throws -> Project {
        let project = Fixtures.makeProject(name, in: context)
        let image = try Fixtures.writePNG(to: folder.file("\(name).png"), width: 40, height: 30)
        let outcomes = await ReferenceImporter(context: context, library: library).importItems(
            [.file(url: image, originalFilename: "\(name).png", resourceURL: nil)],
            into: project, tags: ["Cockpit"]
        )
        guard case .added(let reference) = try #require(outcomes.first) else {
            Issue.record("Expected the image to import, got \(outcomes)")
            return project
        }
        try ImageNoteService(context: context).addNote(
            to: reference, pixelRect: CGRect(x: 2, y: 2, width: 20, height: 20), imageSize: CGSize(width: 40, height: 30)
        )
        let note = try ReferenceService(context: context, library: library)
            .createNote(in: project, title: "Wheel wells", text: "", tagsText: "")
        try FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try Data("poster".utf8).write(to: library.posterURL(referenceID: note.id))

        try PaintService(context: context).add([paint], to: project)

        let parts = AftermarketService(context: context, library: library)
        var draft = AftermarketDraft()
        draft.productName = "Seat"
        draft.type = .resin
        draft.status = .inStash
        let item = try parts.create(in: project, from: draft)
        try await parts.setImage(from: Fixtures.writeJPEG(to: folder.file("\(name)-seat.jpg")), on: item)
        return project
    }

    @Test func deletesEverythingInTheProjectAndKeepsTheCatalogue() async throws {
        var paintDraft = PaintDraft()
        paintDraft.brand = "Tamiya"
        paintDraft.code = "XF-54"
        paintDraft.isOwned = true
        let paint = try PaintService(context: context).createPaint(from: paintDraft)

        let doomed = try await makeFilledProject("F-16", paint: paint)
        let kept = try await makeFilledProject("Spitfire", paint: paint)
        // The list joining ("and", commas) follows the user's language.
        for part in ["2 references", "1 image note,", "1 paint from its paint list", "1 aftermarket part"] {
            #expect(doomed.deletionSummary.contains(part))
        }
        #expect(files(in: library.originalsURL).count == 4)
        #expect(files(in: library.postersURL).count == 2)

        try ProjectService(context: context).delete(doomed, library: library)

        // Only the other project's records and files remain.
        #expect(try context.fetch(FetchDescriptor<Project>()).map(\.name) == ["Spitfire"])
        #expect(try count(Reference.self) == 2)
        #expect(try count(ImageNote.self) == 1)
        #expect(try count(ReferenceTag.self) == 1)
        #expect(try count(ProjectPaint.self) == 1)
        #expect(try count(AftermarketItem.self) == 1)
        #expect(try count(ManagedAsset.self) == 2)
        let keptPaths = Set((kept.references.compactMap(\.asset) + kept.aftermarketItems.compactMap(\.imageAsset))
            .map { URL(filePath: $0.originalRelativePath).lastPathComponent })
        #expect(Set(files(in: library.originalsURL)) == keptPaths)
        #expect(files(in: library.postersURL).count == 1)

        // The catalogue, ownership and tags are unchanged.
        #expect(try count(Paint.self) == 1)
        #expect(paint.ownership != nil)
        #expect(paint.projectSelections.map(\.project?.name) == ["Spitfire"])
        #expect(try context.fetch(FetchDescriptor<BenchBook.Tag>()).map(\.name) == ["Cockpit"])

        // Nothing is left for launch cleanup to find.
        let assetsBefore = try count(ManagedAsset.self)
        try ReferenceService(context: context, library: library).reconcileLibrary()
        #expect(try count(ManagedAsset.self) == assetsBefore)
        #expect(Set(files(in: library.originalsURL)) == keptPaths)
    }

    @Test func deletesAnEmptyProject() throws {
        let project = Fixtures.makeProject("Empty", in: context)
        #expect(project.deletionSummary.isEmpty)
        try ProjectService(context: context).delete(project, library: library)
        #expect(try count(Project.self) == 0)
        #expect(!context.hasChanges)
    }
}

import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ProjectActivityTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var references: ReferenceService { ReferenceService(context: context, library: library) }

    private static let longAgo = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    /// Sets the projects' last updated date far in the past, saving without
    /// touching them.
    private func age(_ projects: Project...) throws {
        for project in projects { project.updatedAt = Self.longAgo }
        try context.save()
    }

    @Test func addingANoteUpdatesOnlyItsProject() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        try age(f16, spitfire)

        try references.createNote(in: f16, title: "Cockpit", text: "Grey", tagsText: "")

        #expect(f16.updatedAt > Self.longAgo)
        #expect(spitfire.updatedAt == Self.longAgo)
    }

    @Test func editingAndDeletingAReferenceUpdatesItsProject() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let note = try references.createNote(in: f16, title: "Cockpit", text: "Grey", tagsText: "")

        try age(f16)
        try references.updateDetails(note, title: "Cockpit", note: "Dark grey", tagsText: "")
        #expect(f16.updatedAt > Self.longAgo)

        try age(f16)
        try references.delete(note)
        #expect(f16.updatedAt > Self.longAgo)
    }

    @Test func movingAReferenceUpdatesBothProjects() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let note = try references.createNote(in: f16, title: "Cockpit", text: "Grey", tagsText: "")
        try age(f16, spitfire)

        _ = try ReferenceTransfer(context: context, library: library).transfer([note], to: spitfire, mode: .move)

        #expect(f16.updatedAt > Self.longAgo)
        #expect(spitfire.updatedAt > Self.longAgo)
    }

    @Test func taggingUpdatesTheProjectButRenamingATagDoesNot() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let note = try references.createNote(in: f16, title: "Cockpit", text: "Grey", tagsText: "")
        let tags = TagService(context: context)
        let tag = try tags.createTag(named: "Interior")

        try age(f16)
        try tags.add(tag, to: [note])
        #expect(f16.updatedAt > Self.longAgo)

        try age(f16)
        _ = try tags.rename(tag, to: "Cockpit")
        #expect(f16.updatedAt == Self.longAgo)
    }

    @Test func deletingABuildPhotoUpdatesItsProject() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let photo = BuildPhoto(project: f16, takenAt: .now, stageRaw: BuildPhotoStage.wip.rawValue)
        context.insert(photo)
        try age(f16)

        try BuildPhotoService(context: context, library: library).delete([photo])

        #expect(f16.updatedAt > Self.longAgo)
    }

    @Test func sortsByNameDateCreatedOrLastUpdated() {
        let day: TimeInterval = 86_400
        let a = Project(name: "a10", createdAt: Date(timeIntervalSince1970: 3 * day))
        let b = Project(name: "A2", createdAt: Date(timeIntervalSince1970: 1 * day))
        let c = Project(name: "B1", createdAt: Date(timeIntervalSince1970: 2 * day))
        a.updatedAt = Date(timeIntervalSince1970: 4 * day)
        b.updatedAt = Date(timeIntervalSince1970: 9 * day)
        c.updatedAt = Date(timeIntervalSince1970: 4 * day)
        let projects = [c, a, b]

        #expect(ProjectSort.name.sorted(projects).map(\.name) == ["A2", "a10", "B1"])
        #expect(ProjectSort.dateCreated.sorted(projects).map(\.name) == ["a10", "B1", "A2"])
        // a10 and B1 were updated at the same time, so they're in name order.
        #expect(ProjectSort.lastUpdated.sorted(projects).map(\.name) == ["A2", "a10", "B1"])
    }
}

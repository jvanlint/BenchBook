import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ProjectServiceTests {
    private static func f16Draft() -> ProjectDraft {
        var draft = ProjectDraft()
        draft.name = "  Tamiya F-16CJ 50th Anniversary  "
        draft.manufacturer = "Tamiya"
        draft.subject = "F-16CJ Block 50"
        draft.scale = "1:48"
        draft.kitNumber = "   "
        draft.markingsScheme = "Galaxy Models 50th Anniversary 2015"
        draft.notes = ""
        return draft
    }

    /// Callers must keep the container alive while using its context.
    private func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)
        return try PersistenceController.makeContainer(configuration: configuration)
    }

    @Test func createTrimsTextAndStoresBlankOptionalsAsNil() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let project = try ProjectService(context: context).createProject(from: Self.f16Draft())

        #expect(project.name == "Tamiya F-16CJ 50th Anniversary")
        #expect(project.summary == "Tamiya · 1:48 · F-16CJ Block 50")
        #expect(project.kitNumber == nil)
        #expect(project.notes == nil)
        #expect(project.markingsScheme == "Galaxy Models 50th Anniversary 2015")
        #expect(project.createdAt == project.updatedAt)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func createRejectsBlankName(name: String) throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        var draft = Self.f16Draft()
        draft.name = name

        #expect(throws: ProjectServiceError.blankName) {
            try ProjectService(context: context).createProject(from: draft)
        }
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
    }

    @Test func updateChangesFieldsAndTimestamp() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let service = ProjectService(context: context)
        let project = try service.createProject(from: Self.f16Draft())
        let originalUpdatedAt = project.updatedAt

        var draft = ProjectDraft(project: project)
        draft.kitNumber = "61098"
        draft.markingsScheme = ""
        draft.notes = "Wheel wells need extra detail."
        try service.update(project, from: draft)

        #expect(project.kitNumber == "61098")
        #expect(project.markingsScheme == nil)
        #expect(project.notes == "Wheel wells need extra detail.")
        #expect(project.updatedAt >= originalUpdatedAt)
    }

    @Test func updateRejectsBlankNameAndLeavesProjectUnchanged() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let service = ProjectService(context: context)
        let project = try service.createProject(from: Self.f16Draft())

        var draft = ProjectDraft(project: project)
        draft.name = "  "
        draft.scale = "1:72"

        #expect(throws: ProjectServiceError.blankName) {
            try service.update(project, from: draft)
        }
        #expect(project.name == "Tamiya F-16CJ 50th Anniversary")
        #expect(project.scale == "1:48")
    }

    /// Simulates quit and relaunch: close the container, open a new one on the same file.
    @Test func createdAndEditedProjectsSurviveReopeningTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BenchBookTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Library.store")

        let projectID: UUID
        do {
            let configuration = ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
            let container = try PersistenceController.makeContainer(configuration: configuration)
            let service = ProjectService(context: container.mainContext)

            let project = try service.createProject(from: Self.f16Draft())
            projectID = project.id
            var draft = ProjectDraft(project: project)
            draft.kitNumber = "61098"
            try service.update(project, from: draft)

            var second = ProjectDraft()
            second.name = "Second Build"
            try service.createProject(from: second)
        }

        let configuration = ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        let reopened = try PersistenceController.makeContainer(configuration: configuration)
        let projects = try reopened.mainContext.fetch(
            FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        )

        #expect(projects.map(\.name) == ["Second Build", "Tamiya F-16CJ 50th Anniversary"])
        let f16 = try #require(projects.first { $0.id == projectID })
        #expect(f16.kitNumber == "61098")
        #expect(f16.summary == "Tamiya · 1:48 · F-16CJ Block 50")
    }
}

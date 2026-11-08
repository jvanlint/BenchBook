import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ProjectStatusTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: ProjectService { ProjectService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    @Test func newProjectsAreResearchingAndStatusCanChange() throws {
        var draft = ProjectDraft()
        draft.name = "F-16CJ"
        let project = try service.createProject(from: draft)
        #expect(project.status == .researching)

        var edited = ProjectDraft(project: project)
        edited.status = .inProgress
        try service.update(project, from: edited)
        #expect(project.statusRaw == "inProgress")

        try service.setStatus(.completed, for: project)
        #expect(project.status == .completed)
        #expect(!context.hasChanges)
    }

    @Test func projectsWithoutAStatusAreResearching() {
        let project = Fixtures.makeProject("Old build", in: context)
        project.statusRaw = nil
        #expect(project.status == .researching)
        project.statusRaw = "something else"
        #expect(project.status == .researching)
    }

    @Test func filterShowsAllOrOneStatus() {
        #expect(ProjectStatusFilter.all.includes(.paused))
        #expect(ProjectStatusFilter.status(.paused).includes(.paused))
        #expect(!ProjectStatusFilter.status(.paused).includes(.completed))

        // Remembered between launches as text.
        for filter in [ProjectStatusFilter.all] + ProjectStatus.allCases.map(ProjectStatusFilter.status) {
            #expect(ProjectStatusFilter(storageValue: filter.storageValue) == filter)
        }
        #expect(ProjectStatusFilter(storageValue: "unknown") == .all)
    }
}

/// Libraries from the Aftermarket release open with every project Researching.
@MainActor
struct MigrationV9Tests {
    @Test func migratesVersion9LibraryToVersion10() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")

        do {
            let v9Schema = Schema(versionedSchema: BenchBookSchemaV9.self)
            let v9 = try ModelContainer(for: v9Schema, configurations: ModelConfiguration(schema: v9Schema, url: storeURL))
            let project = BenchBookSchemaV9.Project(name: "F-16", scale: "1:48")
            v9.mainContext.insert(project)
            v9.mainContext.insert(BenchBookSchemaV9.AftermarketItem(
                project: project, productName: "FOD cover", typeRaw: "printed3D", statusRaw: "considering"
            ))
            try v9.mainContext.save()
        }

        let current = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let project = try #require(try current.mainContext.fetch(FetchDescriptor<Project>()).first)
        #expect(project.scale == "1:48")
        #expect(project.statusRaw == nil)
        #expect(project.status == .researching)
        #expect(project.aftermarketItems.first?.productName == "FOD cover")
    }
}

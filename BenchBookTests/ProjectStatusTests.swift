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

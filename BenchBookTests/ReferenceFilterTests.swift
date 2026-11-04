import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ReferenceFilterTests {
    @Test func filtersByTypeAndRequiresEverySelectedTag() async throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let importer = ReferenceImporter(context: context, library: AssetLibrary(rootURL: folder.url))
        let project = Fixtures.makeProject("F-16", in: context)

        _ = await importer.importItems([.text("a", sourceURL: nil, title: nil)], into: project, tags: ["Wheel Well", "Cockpit"])
        _ = await importer.importItems([.text("b", sourceURL: nil, title: nil)], into: project, tags: ["wheel well"])
        _ = await importer.importItems([.link(url: URL(string: "https://example.com")!, title: nil)], into: project, tags: ["Wheel Well"])
        let refs = project.references
        func count(_ filter: ReferenceFilter) -> Int { refs.filter(filter.matches).count }

        #expect(count(ReferenceFilter()) == 3)
        #expect(count(ReferenceFilter(kind: .textSnippet)) == 2)
        #expect(count(ReferenceFilter(kind: .webpage)) == 1)
        #expect(count(ReferenceFilter(tags: ["wheel well"])) == 3)
        #expect(count(ReferenceFilter(tags: ["wheel well", "cockpit"])) == 1)
        #expect(count(ReferenceFilter(kind: .webpage, tags: ["cockpit"])) == 0)

        let usage = TagUsage.summarize(refs)
        #expect(usage.map(\.name) == ["Wheel Well", "Cockpit"])
        #expect(usage.map(\.count) == [3, 1])
    }

    @Test func togglesAndPrunesSelections() {
        var filter = ReferenceFilter(kind: .pdf, tags: ["decals"])
        filter.toggle(tag: "cockpit")
        filter.toggle(tag: "decals")
        #expect(filter.tags == ["cockpit"])

        filter.prune(availableKinds: [.image], availableTags: ["wheel well"])
        #expect(filter == ReferenceFilter())
        #expect(!filter.isActive)
    }
}

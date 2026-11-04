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

@MainActor
struct NoteTests {
    @Test func createsEditsAndValidatesNotes() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let folder = try TemporaryFolder()
        let service = ReferenceService(context: context, library: AssetLibrary(rootURL: folder.url))
        let project = Fixtures.makeProject("Spitfire", in: context)

        let note = try service.createNote(in: project, title: "  ", text: "\n  Mask canopy first.\n  Then pre-shade.\n", tagsText: "canopy, Masking")
        #expect(note.kind == .note)
        #expect(note.title == nil)
        #expect(note.text == "Mask canopy first.\n  Then pre-shade.")
        #expect(note.displayTitle == "Mask canopy first.")
        #expect(note.tags.map(\.name) == ["canopy", "Masking"])
        #expect(project.references.count == 1)

        try service.updateNote(note, title: "Canopy", text: "Liquid mask only.", tagsText: "canopy")
        #expect(note.displayTitle == "Canopy")
        #expect(note.tags.count == 1)

        #expect(throws: NoteError.empty) {
            try service.updateNote(note, title: " ", text: "\n", tagsText: "")
        }
        #expect(throws: NoteError.empty) {
            try service.createNote(in: project, title: "", text: "", tagsText: "")
        }
        #expect(note.text == "Liquid mask only.")
        #expect(try context.fetchCount(FetchDescriptor<Reference>()) == 1)
    }
}

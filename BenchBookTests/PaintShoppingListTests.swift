import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct PaintShoppingListTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var paints: PaintService { PaintService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func paint(_ brand: String, _ range: String, _ code: String, _ name: String,
                       standard: String = "", owned: Bool = false) throws -> Paint {
        var draft = PaintDraft()
        draft.brand = brand
        draft.range = range
        draft.code = code
        draft.name = name
        draft.standardCode = standard
        draft.isOwned = owned
        return try paints.createPaint(from: draft)
    }

    private func currentList() throws -> PaintShoppingList {
        PaintShoppingList(selections: try context.fetch(FetchDescriptor<ProjectPaint>()))
    }

    @Test func listsUnownedPaintsForUnfinishedProjects() throws {
        let f16 = Fixtures.makeProject("F-16C", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let done = Fixtures.makeProject("Mustang", in: context)
        try ProjectService(context: context).setStatus(.paused, for: spitfire)
        try ProjectService(context: context).setStatus(.completed, for: done)

        let grey = try paint("Tamiya", "Acrylic XF", "XF-54", "Dark Sea Grey", standard: "BS 640")
        let black = try paint("tamiya ", "Acrylic XF", "XF-1", "Flat Black")
        let gray = try paint("Mr. Color", "Lacquer", "C307", "Gray", standard: "FS 36320")
        let owned = try paint("Tamiya", "Acrylic XF", "XF-2", "Flat White", owned: true)
        let finishedOnly = try paint("AK", "Real Colors", "RC001", "White")
        _ = try paint("Vallejo", "Model Air", "71.001", "White")  // in no project

        try paints.add([grey, black, owned], to: f16)
        try paints.add([grey, gray], to: spitfire)
        try paints.add([finishedOnly], to: done)
        let greyOnF16 = try #require(f16.paintRequirements.first { $0.selectedPaint?.id == grey.id })
        paints.setUsedFor("upper surfaces", on: greyOnF16)
        try paints.commit()

        #expect(grey.isToBuy && black.isToBuy && gray.isToBuy)
        #expect(!owned.isToBuy)
        #expect(!finishedOnly.isToBuy)

        let list = try currentList()
        // Paints used by two projects appear once; brand spellings are grouped.
        #expect(list.groups.map(\.name) == ["Mr. Color", "Tamiya"])
        #expect(list.items.map(\.code) == ["C307", "XF-1", "XF-54"])
        #expect(list.summary == "3 paints for 2 projects")

        let date = try Date("2026-11-09T12:00:00Z", strategy: .iso8601)
        let lines = list.text(on: date).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Paint Shopping List")
        #expect(lines[1].hasSuffix(" · 3 paints for 2 projects"))
        #expect(Array(lines.dropFirst(2)) == [
            "",
            "Mr. Color",
            "☐ C307 Gray · Lacquer · FS 36320",
            "    Spitfire",
            "",
            "Tamiya",
            "☐ XF-1 Flat Black · Acrylic XF",
            "    F-16C",
            "☐ XF-54 Dark Sea Grey · Acrylic XF · BS 640",
            "    F-16C (upper surfaces), Spitfire",
            "",
        ])

        // Owning a paint, or finishing its only project, takes it off the list.
        try paints.setOwned(true, for: gray)
        try ProjectService(context: context).setStatus(.completed, for: f16)
        #expect(try currentList().items.map(\.code) == ["XF-54"])
        #expect(try currentList().items.first?.usesLine == "Spitfire")
    }

    @Test func emptyListAndFilename() throws {
        #expect(try currentList().isEmpty)
        let date = try Date("2026-11-09T12:00:00Z", strategy: .iso8601)
        #expect(PaintShoppingList.filename(on: date) == "Paint Shopping List 2026-11-09")
    }
}

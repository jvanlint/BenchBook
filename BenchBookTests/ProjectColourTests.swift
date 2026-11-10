import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct PaintSearchTests {
    private func matches(_ query: String, standard: String) -> Bool {
        PaintIdentity.matches(query, brand: "Mr. Color", range: "Lacquer", code: "C307", name: "Gray", standard: standard)
    }

    @Test func standardsIgnoreSpacingAndPunctuation() {
        #expect(matches("FS 36270", standard: "FS36270"))
        #expect(matches("fs36270", standard: "FS 36270 / BS 637"))
        #expect(matches("FS-36270", standard: "FS 36270"))
        #expect(!matches("FS 36270", standard: "FS 36320"))
        #expect(!matches("FS 36270", standard: ""))
    }

    @Test func otherFieldsStillMatch() {
        #expect(matches("", standard: ""))
        #expect(matches("gray", standard: ""))
        #expect(matches("C307", standard: ""))
        #expect(!matches("Tamiya", standard: ""))
    }
}

@MainActor
struct ProjectColourTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: PaintService { PaintService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func paint(_ brand: String, _ code: String, standard: String = "", owned: Bool = false) throws -> Paint {
        var draft = PaintDraft()
        draft.brand = brand
        draft.code = code
        draft.standardCode = standard
        draft.isOwned = owned
        return try service.createPaint(from: draft)
    }

    @Test func colourWaitsForAPaintThenTakesOne() throws {
        let f16 = Fixtures.makeProject("F-16C", in: context)
        let black = try paint("Tamiya", "XF-1")
        try service.add([black], to: f16)
        let lower = try service.addColour(standard: " FS 36375 ", usedFor: "lower surfaces", to: f16)
        let upper = try service.addColour(standard: "FS 36270", to: f16)

        #expect(lower.standard == "FS 36375")
        #expect(upper.usedFor == nil)
        #expect(Set(f16.unchosenColours.map(\.id)) == [lower.id, upper.id])
        // Colours without a paint come first, by standard.
        #expect(f16.sortedPaintRequirements.map(\.id) == [upper.id, lower.id, f16.sortedPaintRequirements[2].id])
        #expect(f16.sortedPaintRequirements.last?.selectedPaint?.id == black.id)

        let grey = try paint("Mr. Color", "C307", standard: "FS 36270")
        try service.choose(grey, for: upper)
        #expect(upper.selectedPaint?.id == grey.id)
        #expect(upper.standard == "FS 36270")
        #expect(grey.projectNames == ["F-16C"])
        #expect(f16.unchosenColours.map(\.id) == [lower.id])

        // Changing the paint frees the old one.
        let other = try paint("Gunze", "H308", standard: "FS 36270")
        try service.choose(other, for: upper)
        #expect(grey.projectSelections.isEmpty)
        #expect(other.projectNames == ["F-16C"])
    }

    @Test func standardCanBeEditedOnAnyRow() throws {
        let f16 = Fixtures.makeProject("F-16C", in: context)
        let grey = try paint("Mr. Color", "C307")
        try service.add([grey], to: f16)
        let row = try #require(f16.paintRequirements.first)
        service.setStandard("FS 36270", on: row)
        try service.commit()
        #expect(row.standard == "FS 36270")
        service.setStandard("", on: row)
        #expect(row.standard == nil)
    }

    @Test func shoppingListShowsColoursWithoutPaint() throws {
        let f16 = Fixtures.makeProject("F-16C", in: context)
        let done = Fixtures.makeProject("Mustang", in: context)
        try ProjectService(context: context).setStatus(.completed, for: done)
        try service.addColour(standard: "FS 36270", usedFor: "upper surfaces", to: f16)
        try service.addColour(standard: "FS 34092", to: done)

        let list = PaintShoppingList(selections: try context.fetch(FetchDescriptor<ProjectPaint>()))
        #expect(!list.isEmpty)
        #expect(list.items.isEmpty)
        #expect(list.unchosen.map(\.standard) == ["FS 36270"])
        #expect(list.unchosen.first?.useLine == "F-16C (upper surfaces)")
        #expect(list.summary == "1 colour without paint")
        #expect(list.text().contains("No Paint Chosen\n☐ FS 36270\n    F-16C (upper surfaces)\n"))
    }
}

@MainActor
struct MigrationV10Tests {
    @Test func migratesVersion10LibraryToVersion11() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")

        do {
            let v10Schema = Schema(versionedSchema: BenchBookSchemaV10.self)
            let v10 = try ModelContainer(for: v10Schema, configurations: ModelConfiguration(schema: v10Schema, url: storeURL))
            let project = BenchBookSchemaV10.Project(name: "F-16C")
            v10.mainContext.insert(project)
            let paint = BenchBookSchemaV10.Paint(brand: "Mr. Color", code: "C307", identityKey: "mr color||c307")
            v10.mainContext.insert(paint)
            v10.mainContext.insert(BenchBookSchemaV10.ProjectPaint(project: project, paint: paint, usedFor: "Upper surfaces"))
            try v10.mainContext.save()
        }

        let current = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let row = try #require(try current.mainContext.fetch(FetchDescriptor<ProjectPaint>()).first)
        #expect(row.selectedPaint?.code == "C307")
        #expect(row.usedFor == "Upper surfaces")
        #expect(row.standard == nil)
        #expect(row.project?.name == "F-16C")
    }
}

import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct PaintMixTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: PaintService { PaintService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func paint(_ code: String, _ name: String, owned: Bool = false) throws -> Paint {
        var draft = PaintDraft()
        draft.brand = "Tamiya"
        draft.code = code
        draft.name = name
        draft.isOwned = owned
        return try service.createPaint(from: draft)
    }

    private func mixDraft(_ name: String, _ recipe: [(Paint, Double)], brand: String = "Custom") -> PaintDraft {
        var draft = PaintDraft()
        draft.isMix = true
        draft.brand = brand
        draft.name = name
        draft.recipe = recipe.map { MixPartDraft(paintID: $0.0.id, parts: $0.1) }
        return draft
    }

    @Test func aMixNeedsNoCodeAndIsKnownByBrandAndName() throws {
        let white = try paint("XF-2", "Flat White")
        let grey = try paint("XF-19", "Sky Grey")
        let mix = try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3), (grey, 1)]))

        #expect(mix.isMix && mix.code.isEmpty)
        #expect(mix.recipePaints.map(\.code) == ["XF-2", "XF-19"])
        #expect(mix.recipeSummary == "3 parts XF-2, 1 part XF-19")
        #expect(mix.secondaryLine == "Mix: 3 parts XF-2, 1 part XF-19")
        #expect(mix.displayName == "Custom Faded Sky Grey")

        #expect(throws: PaintServiceError.duplicate("Custom Faded Sky Grey")) {
            try service.createPaint(from: mixDraft(" faded  sky grey", [], brand: "custom"))
        }
        // A mix with the same name under another brand is fine.
        try service.createPaint(from: mixDraft("Faded Sky Grey", [], brand: "Jason"))

        #expect(throws: PaintServiceError.missingBrandOrName) {
            try service.createPaint(from: mixDraft("", [(white, 1)]))
        }
    }

    @Test func recipesAreChecked() throws {
        let white = try paint("XF-2", "Flat White")
        #expect(throws: PaintServiceError.badParts) {
            try service.createPaint(from: mixDraft("Zero", [(white, 0)]))
        }
        #expect(throws: PaintServiceError.badRecipePaint) {
            try service.createPaint(from: mixDraft("Twice", [(white, 1), (white, 2)]))
        }
        let mix = try service.createPaint(from: mixDraft("Grey", [(white, 1)]))
        // A mix can't be in a recipe, including its own.
        #expect(throws: PaintServiceError.badRecipePaint) {
            try service.createPaint(from: mixDraft("Of a mix", [(mix, 1)]))
        }
        #expect(throws: PaintServiceError.badRecipePaint) {
            var draft = PaintDraft(paint: mix)
            draft.recipe.append(MixPartDraft(paintID: mix.id))
            try service.update(mix, from: draft)
        }
    }

    @Test func editingReplacesTheRecipe() throws {
        let white = try paint("XF-2", "Flat White")
        let grey = try paint("XF-19", "Sky Grey")
        let mix = try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3), (grey, 1)]))

        var draft = PaintDraft(paint: mix)
        #expect(draft.recipe == [MixPartDraft(paintID: white.id, parts: 3), MixPartDraft(paintID: grey.id, parts: 1)])
        draft.recipe = [MixPartDraft(paintID: grey.id, parts: 2.5)]
        try service.update(mix, from: draft)

        #expect(mix.recipeSummary == "2.5 parts XF-19")
        #expect(try context.fetchCount(FetchDescriptor<PaintMixPart>()) == 1)
        #expect(white.mixesUsingPaint.isEmpty)
        #expect(grey.mixNames == ["Custom Faded Sky Grey"])
    }

    @Test func recipePaintsMoveUpAndDown() {
        let white = UUID(), grey = UUID(), black = UUID()
        var draft = PaintDraft()
        draft.recipe = [white, grey, black].map { MixPartDraft(paintID: $0) }
        draft.moveRecipePaint(black, by: -1)
        #expect(draft.recipe.map(\.paintID) == [white, black, grey])
        draft.moveRecipePaint(white, by: -1)
        draft.moveRecipePaint(grey, by: 1)
        #expect(draft.recipe.map(\.paintID) == [white, black, grey])
        draft.moveRecipePaint(white, by: 1)
        #expect(draft.recipe.map(\.paintID) == [black, white, grey])
    }

    @Test func aMixIsOwnedWhenEveryRecipePaintIs() throws {
        let white = try paint("XF-2", "Flat White", owned: true)
        let grey = try paint("XF-19", "Sky Grey")
        let empty = try service.createPaint(from: mixDraft("Empty", []))
        let mix = try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3), (grey, 1)]))
        #expect(!empty.isOwned)
        #expect(!mix.isOwned)
        #expect(mix.missingRecipePaints.map(\.code) == ["XF-19"])

        try service.setOwned(true, for: grey)
        #expect(mix.isOwned)
        // Its own ownership can't be set.
        try service.setOwned(false, for: mix)
        #expect(mix.isOwned && mix.ownership == nil)
        #expect(PaintFilter(ownedOnly: true).includes(brand: mix.brand, range: mix.range, isOwned: mix.isOwned))
    }

    @Test func recipePaintsCantBeDeletedButAMixCan() throws {
        let white = try paint("XF-2", "Flat White")
        let mix = try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3)]))

        #expect(throws: PaintServiceError.inRecipe(paint: "Tamiya XF-2 Flat White", mixes: ["Custom Faded Sky Grey"])) {
            try service.delete(white)
        }
        try service.delete(mix)
        #expect(try context.fetchCount(FetchDescriptor<PaintMixPart>()) == 0)
        #expect(white.mixParts.isEmpty)
        try service.delete(white)
        #expect(try context.fetchCount(FetchDescriptor<Paint>()) == 0)
    }

    @Test func aProjectsMixPutsItsMissingPaintsOnTheShoppingList() throws {
        let white = try paint("XF-2", "Flat White", owned: true)
        let grey = try paint("XF-19", "Sky Grey")
        let mix = try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3), (grey, 1)]))
        let f16 = Fixtures.makeProject("F-16C", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        try service.add([mix], to: f16)
        try service.add([grey], to: spitfire)
        let row = try #require(f16.paintRequirements.first)
        service.setUsedFor("upper surfaces", on: row)
        service.setNotes("lightened 20%", on: row)
        try service.commit()
        #expect(row.notes == "lightened 20%")

        #expect(!mix.isToBuy)
        #expect(grey.isToBuy)
        #expect(!white.isToBuy)
        let list = PaintShoppingList(selections: try context.fetch(FetchDescriptor<ProjectPaint>()))
        #expect(list.items.map(\.code) == ["XF-19"])
        #expect(list.items.first?.usesLine == "F-16C (upper surfaces, for Faded Sky Grey), Spitfire")

        // Without a "used for", the mix is the reason.
        service.setUsedFor("", on: row)
        try service.commit()
        let again = PaintShoppingList(selections: try context.fetch(FetchDescriptor<ProjectPaint>()))
        #expect(again.items.first?.usesLine == "F-16C (for Faded Sky Grey), Spitfire")

        // A completed project's mix needs nothing.
        try ProjectService(context: context).setStatus(.completed, for: f16)
        #expect(grey.unfinishedUses.count == 1)
    }

    @Test func mixesArentExported() throws {
        let white = try paint("XF-2", "Flat White")
        try service.createPaint(from: mixDraft("Faded Sky Grey", [(white, 3)]))
        let rows = PaintCSVExporter.rows(for: try context.fetch(FetchDescriptor<Paint>()))
        #expect(rows.map(\.code) == ["XF-2"])
    }
}

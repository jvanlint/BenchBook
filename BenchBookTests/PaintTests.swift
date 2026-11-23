import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct PaintIdentityTests {
    @Test func ignoresCaseSpacingAndCodePunctuation() {
        let key = PaintIdentity.key(brand: "Tamiya", range: "Acrylic XF", code: "XF-54")
        #expect(PaintIdentity.key(brand: " tamiya ", range: "acrylic  xf", code: "xf 54") == key)
        #expect(PaintIdentity.key(brand: "Tamiya", range: "Acrylic XF", code: "XF54") == key)
        #expect(PaintIdentity.key(brand: "Tamiya", range: "Lacquer LP", code: "XF-54") != key)
        #expect(PaintIdentity.key(brand: "Mr. Hobby", range: "", code: "H-335") != PaintIdentity.key(brand: "Mr. Hobby", range: "", code: "H-336"))
    }

    @Test func normalizesSwatchColours() {
        #expect(SwatchColor.normalized("#4a5a6b") == "#4A5A6B")
        #expect(SwatchColor.normalized("abc") == "#AABBCC")
        #expect(SwatchColor.normalized("navy") == nil)
        #expect(SwatchColor.normalized("#12345") == nil)
        #expect(SwatchColor.hex(red: 1, green: 0.5, blue: 0) == "#FF8000")
    }
}

@MainActor
struct PaintServiceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: PaintService { PaintService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func draft(_ brand: String, _ code: String, name: String = "", owned: Bool = false) -> PaintDraft {
        var draft = PaintDraft()
        draft.brand = brand
        draft.range = "Acrylic"
        draft.code = code
        draft.name = name
        draft.isOwned = owned
        return draft
    }

    @Test func createsPaintsAndRejectsDuplicatesAndBlanks() throws {
        let paint = try service.createPaint(from: draft(" Tamiya ", "XF-54", name: "Dark Sea Grey", owned: true))
        #expect(paint.brand == "Tamiya")
        #expect(paint.displayName == "Tamiya XF-54 Dark Sea Grey")
        #expect(paint.isOwned)

        #expect(throws: PaintServiceError.duplicate("Tamiya XF-54 Dark Sea Grey")) {
            try service.createPaint(from: draft("tamiya", "xf54"))
        }
        #expect(throws: PaintServiceError.missingBrandOrCode) {
            try service.createPaint(from: draft("Tamiya", "  "))
        }

        // Editing into another paint's identity is a duplicate too; editing itself isn't.
        let other = try service.createPaint(from: draft("Tamiya", "XF-53"))
        #expect(throws: PaintServiceError.duplicate("Tamiya XF-54 Dark Sea Grey")) {
            try service.update(other, from: draft("Tamiya", "XF-54"))
        }
        var renamed = PaintDraft(paint: paint)
        renamed.name = "Dark Sea Gray"
        renamed.standardSystem = .bs381c
        renamed.standardCode = "  640 "
        renamed.match = .closest
        try service.update(paint, from: renamed)
        #expect(paint.name == "Dark Sea Gray")
        #expect(paint.standardCode == "640")
        #expect(paint.standardText == "BS 640")
        #expect(paint.match == .closest)
        #expect(PaintDraft(paint: paint).standardCode == "640")

        // No standard: the code and match go too.
        renamed.standardSystem = nil
        try service.update(paint, from: renamed)
        #expect(paint.standardSystemRaw.isEmpty && paint.standardCode.isEmpty && paint.matchRaw.isEmpty)
    }

    @Test func removingOwnershipKeepsThePaint() throws {
        let paint = try service.createPaint(from: draft("Vallejo", "70.990", owned: true))
        #expect(try context.fetchCount(FetchDescriptor<OwnedPaint>()) == 1)

        try service.setOwned(false, for: paint)

        #expect(!paint.isOwned)
        #expect(try context.fetchCount(FetchDescriptor<OwnedPaint>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Paint>()) == 1)
    }

    @Test func projectPaintsAddRemoveAndProtectThePaint() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let gray = try service.createPaint(from: draft("Mr. Color", "C307"))
        let white = try service.createPaint(from: draft("Mr. Color", "C316", owned: true))

        #expect(try service.add([gray, white], to: f16) == 2)
        #expect(try service.add([gray], to: f16) == 0)  // already there
        #expect(f16.sortedPaintRequirements.compactMap { $0.selectedPaint?.code } == ["C307", "C316"])

        let row = try #require(f16.sortedPaintRequirements.first)
        service.setUsedFor("Upper surfaces", on: row)
        try service.commit()
        #expect(row.usedFor == "Upper surfaces")

        #expect(throws: PaintServiceError.inUse(paint: "Mr. Color C307", projects: ["F-16"])) {
            try service.delete(gray)
        }

        try service.remove(row)
        #expect(f16.paintRequirements.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Paint>()) == 2)

        // Once off the project it can be deleted; the other is still in use.
        try service.delete(gray)
        #expect(throws: PaintServiceError.self) { try service.delete(white) }
        #expect(try context.fetchCount(FetchDescriptor<Paint>()) == 1)
    }

    @Test func deletingProjectKeepsCataloguePaints() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let paint = try service.createPaint(from: draft("Tamiya", "X-1"))
        try service.add([paint], to: f16)

        context.delete(f16)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ProjectPaint>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Paint>()) == 1)
        #expect(paint.projectSelections.isEmpty)
    }
}

struct CSVParserTests {
    @Test func handlesQuotesCommasLineBreaksAndBlankLines() {
        let text = "Brand,Code,Name\r\nTamiya,XF-54,\"Dark Sea Grey, matt\"\r\n\r\n\"Mr. Hobby\",H-335,\"Medium Sea Grey\nBS 637\"\nAK,RC001,\"The \"\"real\"\" white\"\n"
        let rows = CSVParser.parse(text)
        #expect(rows.map(\.fields) == [
            ["Brand", "Code", "Name"],
            ["Tamiya", "XF-54", "Dark Sea Grey, matt"],
            ["Mr. Hobby", "H-335", "Medium Sea Grey\nBS 637"],
            ["AK", "RC001", "The \"real\" white"],
        ])
        #expect(rows.map(\.line) == [1, 2, 4, 6])
    }
}

@MainActor
struct PaintCSVImporterTests {
    @Test func importsAddsSkipsAndReports() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        var existing = PaintDraft()
        existing.brand = "Tamiya"
        existing.range = "Acrylic XF"
        existing.code = "XF-54"
        try PaintService(context: context).createPaint(from: existing)

        let csv = """
        Manufacturer,Range,Code,Colour Name,Hex,Owned,Notes
        Tamiya,Acrylic XF,XF-53,Neutral Grey,#7A7D80,yes,
        Tamiya,Acrylic XF,xf 54,Dark Sea Grey,,no,
        Mr. Color,Lacquer,C307,Gray FS36320,6E7377,1,"Thin 1:1"
        Mr. Color,Lacquer,C307,Gray (again),,,
        Vallejo,Model Air,,No code,,,
        AK,3rd Gen,AK11001,White,not a colour,x,
        """
        let summary = try PaintCSVImporter(context: context).importCSV(csv)

        #expect(summary.added == 3)
        #expect(summary.updated == 1)
        #expect(summary.repeated == 1)
        #expect(summary.problems.count == 2)
        #expect(summary.problems.contains { $0.hasPrefix("Line 6:") })
        #expect(summary.problems.contains { $0.hasPrefix("Line 7:") })

        let paints = try context.fetch(FetchDescriptor<Paint>())
        let c307 = try #require(paints.first { $0.code == "C307" })
        #expect(c307.name == "Gray FS36320")
        #expect(c307.swatchHex == "#6E7377")
        #expect(c307.isOwned)
        #expect(c307.notes == "Thin 1:1")
        let white = try #require(paints.first { $0.code == "AK11001" })
        #expect(white.swatchHex == nil && white.isOwned)
    }

    /// The issue's test: the same file with only Owned changed updates
    /// ownership and adds nothing.
    @Test func reimportingUpdatesOwnershipOnly() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let first = """
        Brand,Range,Code,Name,Colour,Owned,Notes
        Tamiya,Acrylic XF,XF-1,Flat Black,#202020,,Thin 1:1
        Tamiya,Acrylic XF,XF-2,Flat White,#F0F0F0,yes,
        """
        _ = try PaintCSVImporter(context: context).importCSV(first)
        let second = first.replacingOccurrences(of: "#202020,,", with: "#202020,yes,")
            .replacingOccurrences(of: "#F0F0F0,yes,", with: "#F0F0F0,no,")
        let summary = try PaintCSVImporter(context: context).importCSV(second)
        #expect(summary == PaintCSVImporter.Summary(added: 0, updated: 2))

        let paints = try context.fetch(FetchDescriptor<Paint>())
        #expect(paints.count == 2)
        #expect(paints.first { $0.code == "XF-1" }?.isOwned == true)
        #expect(paints.first { $0.code == "XF-2" }?.isOwned == false)
        #expect(paints.first { $0.code == "XF-1" }?.notes == "Thin 1:1")

        let again = try PaintCSVImporter(context: context).importCSV(second)
        #expect(again == PaintCSVImporter.Summary(unchanged: 2))
    }

    @Test func blankCellsLeaveValuesUnchanged() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        var draft = PaintDraft()
        draft.brand = "Mr. Color"
        draft.range = "Lacquer"
        draft.code = "C307"
        draft.name = "Gray"
        draft.notes = "Thin 1:1"
        draft.swatchHex = "#6E7377"
        draft.standardSystem = .fs595
        draft.standardCode = "36320"
        draft.match = .exact
        draft.type = .lacquer
        draft.isOwned = true
        let paint = try PaintService(context: context).createPaint(from: draft)

        // Blank cells, and columns the file doesn't have, change nothing.
        let sparse = """
        Brand,Range,Code,Name,Colour,Owned,Notes,Standard,Standard Code,Match,Type
        mr. color,LACQUER,c 307,,,,,,,,
        """
        #expect(try PaintCSVImporter(context: context).importCSV(sparse) == .init(unchanged: 1))
        #expect(try PaintCSVImporter(context: context).importCSV("Brand,Range,Code\nMr. Color,Lacquer,C307") == .init(unchanged: 1))
        #expect(PaintDraft(paint: paint) == draft)

        // Filled cells change their values; brand, range and code keep the
        // catalogue's spelling.
        let filled = """
        Brand,Range,Code,Name,Colour,Notes,Standard,Standard Code,Match,Type
        mr. color,LACQUER,c 307,Gray FS36320,#707070,Thin 2:1,RAL,7001,Closest match,Enamel
        """
        #expect(try PaintCSVImporter(context: context).importCSV(filled) == .init(updated: 1))
        #expect(paint.brand == "Mr. Color" && paint.range == "Lacquer" && paint.code == "C307")
        #expect(paint.name == "Gray FS36320" && paint.notes == "Thin 2:1" && paint.swatchHex == "#707070")
        #expect(paint.standard == PaintStandard(system: .ral, code: "7001"))
        #expect(paint.match == .closest && paint.type == .enamel && paint.isOwned)
    }

    @Test func unclearOwnedIsReportedAndLeftAlone() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let summary = try PaintCSVImporter(context: context).importCSV("Brand,Code,Owned\nTamiya,XF-1,maybe")
        #expect(summary.added == 1)
        #expect(summary.problems == ["Line 2: “maybe” isn't yes or no, so ownership wasn't changed."])
        #expect(try context.fetch(FetchDescriptor<Paint>()).first?.isOwned == false)
    }

    @Test func importsColourStandards() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let csv = """
        Brand,Code,FS/RLM
        Tamiya,XF-54,BS 640
        Gunze,H-417,RLM 76
        """
        _ = try PaintCSVImporter(context: context).importCSV(csv)

        let separate = """
        Brand,Code,FS,RLM,Notes
        Mr. Color,C117,34102,,
        Mr. Color,C118,36375,RLM 76,
        AK,RC001,FS 17875,,
        """
        let summary = try PaintCSVImporter(context: context).importCSV(separate)
        #expect(summary.added == 3)

        let paints = try context.fetch(FetchDescriptor<Paint>())
        func standard(_ code: String) -> String? { paints.first { $0.code == code }?.standardText }
        #expect(standard("XF-54") == "BS 640")
        #expect(standard("H-417") == "RLM 76")
        #expect(standard("C117") == "FS 34102")
        #expect(standard("C118") == "FS 36375 / RLM 76")
        #expect(standard("RC001") == "FS 17875")
    }

    @Test func requiresBrandAndCodeColumns() throws {
        let container = try Fixtures.makeInMemoryContainer()
        #expect(throws: PaintCSVImporter.ImportError.missingColumns(["Code"])) {
            try PaintCSVImporter(context: container.mainContext).importCSV("Brand,Name\nTamiya,Grey\n")
        }
        #expect(throws: PaintCSVImporter.ImportError.empty) {
            try PaintCSVImporter(context: container.mainContext).importCSV("")
        }
    }
}

/// Removing a paint from a project frees it for deletion in a saved library too.
@MainActor
struct OnDiskPaintRemovalTests {
    @Test func removedPaintCanBeDeletedAfterRelaunch() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("Library.store")
        func open() throws -> ModelContainer {
            try PersistenceController.makeContainer(
                configuration: ModelConfiguration(schema: PersistenceController.schema, url: url)
            )
        }
        do {
            let container = try open()
            let service = PaintService(context: container.mainContext)
            let project = Fixtures.makeProject("F-16", in: container.mainContext)
            var draft = PaintDraft()
            draft.brand = "Tamiya"
            draft.code = "XF-1"
            try service.add([try service.createPaint(from: draft)], to: project)
        }

        let container = try open()
        let service = PaintService(context: container.mainContext)
        let paint = try #require(try container.mainContext.fetch(FetchDescriptor<Paint>()).first)
        let project = try #require(try container.mainContext.fetch(FetchDescriptor<Project>()).first)
        #expect(paint.projectNames == ["F-16"])

        try service.remove(try #require(project.paintRequirements.first))
        #expect(paint.projectNames.isEmpty)
        try service.delete(paint)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Paint>()) == 0)
    }
}

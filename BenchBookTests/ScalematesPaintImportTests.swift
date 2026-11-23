import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct ScalematesPaintImportTests {
    /// The same made-up stash as spec/fixtures/paints-scalemates.csv: ten
    /// named columns but eleven values a row, two bottles of one paint, no
    /// colour (";;"), a bad colour and a company BenchBook doesn't know.
    static let stash = #"""
"Color","Preview","Company","Number","Size","Type","Finish","Condition","Remaining","Link"
"Example Sky","168;181;155","Vallejo Model Air","71.901","17ml","Acrylic","Matt","100","100","S","https://www.scalemates.com/colors/example-sky--900001"
"Example Sky","168;181;155","Vallejo Model Air","71.901","17ml","Acrylic","Matt","100","50","S","https://www.scalemates.com/colors/example-sky--900001"
"Example Steel",";;","AK Interactive","AK 901","35ml","Enamel","Metallic","100","100","S","https://www.scalemates.com/colors/example-steel--900002"
"Example Grey","90;95;100","AK Real Colors","RC901","10ml","Acrylic Lacquer","Satin","100","100","S","https://www.scalemates.com/colors/example-grey--900003"
"Example Primer","20;20;20","Vallejo Surface Primer","70.901","200ml","Acrylic","Matt","100","100","S","https://www.scalemates.com/colors/example-primer--900004"
"Example Dust",";;","Ammo by Mig Jimenez","A.MIG-9901","35ml","Pigments","Matt","100","100","S","https://www.scalemates.com/colors/example-dust--900005"
"Example Blue","10;20;300","Example Paint Co","EX 1","20ml","Acrylic","Gloss","100","100","S","https://www.scalemates.com/colors/example-blue--900006"
"""#

    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var importer: ScalematesPaintImporter { ScalematesPaintImporter(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func paints() throws -> [Paint] {
        try context.fetch(FetchDescriptor<Paint>())
    }

    private func paint(_ brand: String, _ code: String) throws -> Paint? {
        try paints().first { $0.brand == brand && $0.code == code }
    }

    @discardableResult
    private func addPaint(_ brand: String, range: String = "", code: String, name: String = "",
                          notes: String = "", owned: Bool = false) throws -> Paint {
        var draft = PaintDraft()
        draft.brand = brand
        draft.range = range
        draft.code = code
        draft.name = name
        draft.notes = notes
        draft.isOwned = owned
        return try PaintService(context: context).createPaint(from: draft)
    }

    @Test func fixtureMatchesTheTests() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spec/fixtures/paints-scalemates.csv")
        // The fixture ends with a newline; the test text doesn't.
        #expect(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines) == Self.stash)
    }

    @Test func addsNewPaintsOwnedWithTheTableAndNotes() throws {
        let summary = try importer.importCSV(Self.stash)
        #expect(summary.added == 6)
        #expect(summary.sameRows == 1)
        #expect(summary.markedOwned == 0)
        #expect(summary.unknownCompanies == ["Example Paint Co"])
        #expect(summary.problems.count == 1)
        #expect(try paints().allSatisfy(\.isOwned))

        let sky = try #require(try paint("Vallejo", "71.901"))
        #expect(sky.range == "Model Air")
        #expect(sky.name == "Example Sky")
        #expect(sky.swatchHex == "#A8B59B")
        #expect(sky.type == .waterAcrylic)
        // Link is the last value, after the unnamed column.
        #expect(sky.notes == "Matt · 17ml · https://www.scalemates.com/colors/example-sky--900001")
    }

    @Test func mapsTypes() throws {
        _ = try importer.importCSV(Self.stash)
        #expect(try paint("AK Interactive", "AK 901")?.type == .enamel)
        #expect(try paint("AK Interactive", "RC901")?.type == .lacquer)
        #expect(try paint("AK Interactive", "RC901")?.range == "Real Color")
        #expect(try paint("Vallejo", "70.901")?.type == .polyurethane)
        #expect(try paint("Ammo by Mig", "A.MIG-9901")?.type == .pigment)
        // Unknown company: the whole name is the brand, with no range or type.
        let blue = try #require(try paint("Example Paint Co", "EX 1"))
        #expect(blue.range == "" && blue.type == nil)
    }

    @Test func noColourAndBadColourLeaveNoSwatch() throws {
        let summary = try importer.importCSV(Self.stash)
        #expect(try paint("AK Interactive", "AK 901")?.swatchHex == nil)
        #expect(try paint("Example Paint Co", "EX 1")?.swatchHex == nil)
        #expect(summary.problems.first?.contains("10;20;300") == true)
    }

    @Test func existingPaintIsOnlyMarkedOwned() throws {
        // Another range and the code written differently: still the same paint.
        let existing = try addPaint("Vallejo", range: "Air", code: "71901", name: "My Sky", notes: "Mine")
        let summary = try importer.importCSV(Self.stash)
        #expect(summary.markedOwned == 1)
        #expect(summary.added == 5)
        #expect(existing.isOwned)
        #expect(existing.name == "My Sky" && existing.notes == "Mine" && existing.range == "Air")
        #expect(existing.swatchHex == nil && existing.type == nil)
        #expect(try paints().filter { $0.brand == "Vallejo" && $0.code.contains("901") && $0.range != "Surface Primer" }.count == 1)
    }

    @Test func countsAlreadyOwnedAndKeepsPaintsNotInTheFile() throws {
        try addPaint("Vallejo", range: "Model Air", code: "71.901", owned: true)
        let other = try addPaint("Tamiya", code: "XF-1", owned: true)
        let summary = try importer.importCSV(Self.stash)
        #expect(summary.alreadyOwned == 1)
        #expect(summary.markedOwned == 0)
        #expect(other.isOwned)
    }

    @Test func severalMatchesPickTheTablesRange() throws {
        let air = try addPaint("Vallejo", range: "Model Air", code: "71.901")
        let other = try addPaint("Vallejo", range: "Game Air", code: "71.901")
        _ = try importer.importCSV(Self.stash)
        #expect(air.isOwned)
        #expect(!other.isOwned)
    }

    @Test func severalMatchesOutsideTheRangeAreLeftAlone() throws {
        let one = try addPaint("AK Interactive", range: "Enamel", code: "AK901")
        let two = try addPaint("AK Interactive", range: "Weathering", code: "AK-901")
        let summary = try importer.importCSV(Self.stash)
        #expect(!one.isOwned && !two.isOwned)
        #expect(summary.problems.contains { $0.contains("AK 901") })
        #expect(try paints().filter { $0.brand == "AK Interactive" && $0.code.contains("901") && $0.range != "Real Color" }.count == 2)
    }

    @Test func mixesAreNeverMatched() throws {
        var draft = PaintDraft()
        draft.isMix = true
        draft.brand = "Ammo by Mig"
        draft.code = "A.MIG-9901"
        draft.name = "My Dust Mix"
        let mix = try PaintService(context: context).createPaint(from: draft)
        let summary = try importer.importCSV(Self.stash)
        #expect(summary.added == 6)
        #expect(!mix.isOwned)
    }

    @Test func skipsRowsWithoutCompanyOrNumber() throws {
        let text = #"""
"Color","Preview","Company","Number","Size","Type","Finish","Condition","Remaining","Link"
"No Number",";;","Vallejo Model Air","","17ml","Acrylic","Matt","100","100","S",""
"""#
        let summary = try importer.importCSV(text)
        #expect(summary.added == 0)
        #expect(summary.problems == ["Line 2: a paint needs a company and a number, so it was skipped."])
    }

    @Test func refusesOtherFiles() throws {
        #expect(throws: ScalematesPaintImporter.ImportError.notScalemates) {
            try importer.importCSV("Brand,Code,Name\nTamiya,XF-1,Flat Black")
        }
        #expect(throws: ScalematesPaintImporter.ImportError.empty) {
            try importer.importCSV(#""Color","Preview","Company","Number""#)
        }
    }
}

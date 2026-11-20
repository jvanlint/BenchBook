import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct KitCSVTests {
    /// The same made-up stash as spec/fixtures/kits-scalemates.csv: two
    /// copies of one kit, two single kits, and three rows that aren't kits.
    static let scalemates = #"""
"Scale","Title","Brand","Number","Type","Topic","Price","Bought on","Bought at","Location","Room","Shelf","Box","Link"
"1:72","AH-1W Super Cobra","Italeri","1234","Static model kits","Bell AH-1W SuperCobra"," 0","0000-00-00","","","","","","https://www.scalemates.com/kits/italeri-1234-ah-1w-super-cobra--100001"
"1:72","AH-1W Super Cobra","Italeri","1234","Static model kits","Bell AH-1W SuperCobra","18,50","2025-03-01","Model shop","","","","","https://www.scalemates.com/kits/italeri-1234-ah-1w-super-cobra--100001"
"1:48","Spitfire Mk.I","Airfix","A05126","Static model kits","Supermarine Spitfire Mk.I","25.00","0000-00-00","","Garage","","Top","3","https://www.scalemates.com/kits/airfix-a05126-spitfire-mk-i--100002"
"1:48","F-16C ""Viper"" Block 50","Tamiya","61098","Static model kits","General Dynamics F-16C"," 0","0000-00-00","","","","","","https://www.scalemates.com/kits/tamiya-61098-f-16c-viper--100003"
"1:48","F-16C Decals","Two Bobs","48-123","Markings (Decals)","General Dynamics F-16C"," 0","0000-00-00","","","","","","https://www.scalemates.com/products/two-bobs-48-123--100004"
"1:48","F-16C Cockpit","Aires","4561","Detail and Conversion sets","General Dynamics F-16C"," 0","0000-00-00","","","","","","https://www.scalemates.com/products/aires-4561--100005"
"1:48","F-16 Stencils","Two Bobs","48-200","Markings (Decals)","General Dynamics F-16"," 0","0000-00-00","","","","","","https://www.scalemates.com/products/two-bobs-48-200--100006"
"""#

    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: KitService { KitService(context: context, library: library) }
    var importer: KitCSVImporter { KitCSVImporter(context: context) }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func kits(_ brand: String? = nil) throws -> [Kit] {
        try context.fetch(FetchDescriptor<Kit>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { brand == nil || $0.brand == brand }
    }

    @discardableResult
    private func addKit(_ brand: String, _ name: String, number: String, scale: String, owned: Bool = true) throws -> Kit {
        var draft = KitDraft()
        draft.brand = brand
        draft.name = name
        draft.number = number
        draft.scale = scale
        draft.isOwned = owned
        return try service.create(from: draft)
    }

    // MARK: Scalemates

    @Test func importsOneEntryPerRowAndSkipsRowsThatArentKits() throws {
        let summary = try importer.importCSV(Self.scalemates)

        #expect(summary.added == 4)
        #expect(summary.skipped.map(\.type) == ["Markings (Decals)", "Detail and Conversion sets"])
        #expect(summary.skipped.map(\.count) == [2, 1])
        #expect(summary.problems.isEmpty)

        let cobras = try kits("Italeri")
        #expect(cobras.count == 2)
        #expect(cobras.allSatisfy { $0.isOwned && $0.status == .bnib && $0.stars == nil })
        #expect(cobras.allSatisfy { $0.scale == "1:72" && $0.number == "1234" })
        // " 0" means no price; "18,50" is read with a decimal comma.
        #expect(cobras.map(\.pricePaid) == [nil, Decimal(string: "18.5")])
        #expect(try kits("Tamiya").first?.name == #"F-16C "Viper" Block 50"#)
        #expect(try kits("Airfix").first?.pricePaid == 25)
    }

    @Test func importingTheSameFileAgainAddsNothing() throws {
        try importer.importCSV(Self.scalemates)
        let again = try importer.importCSV(Self.scalemates)

        #expect(again.added == 0)
        #expect(again.updated == 0)
        #expect(again.unchanged == 4)
        #expect(try kits().count == 4)
    }

    @Test func kitsThatArentOwnedBecomeOwnedBeforeNewOnesAreAdded() throws {
        let wanted = try addKit("Italeri", "Super Cobra", number: "1234", scale: "1:72", owned: false)

        let summary = try importer.importCSV(Self.scalemates)

        #expect(wanted.isOwned)
        #expect(try kits("Italeri").count == 2)
        #expect(summary.added == 3)
        #expect(summary.updated == 1)
        // The file's details win: its title replaces the hand-typed name.
        #expect(wanted.name == "AH-1W Super Cobra")
    }

    @Test func importNeverRemovesCopiesOrKitsMissingFromTheFile() throws {
        for _ in 0..<3 { try addKit("Airfix", "Spitfire Mk.I", number: "A05126", scale: "1:48") }
        let other = try addKit("Revell", "Lancaster", number: "04300", scale: "1:72")

        let summary = try importer.importCSV(Self.scalemates)

        #expect(try kits("Airfix").count == 3)
        #expect(try kits("Revell") == [other])
        #expect(summary.added == 3)
    }

    @Test func pricesOnlyFillEntriesWithoutOne() throws {
        let first = try addKit("Italeri", "Super Cobra", number: "1234", scale: "1:72")
        first.pricePaid = 30
        let second = try addKit("Italeri", "Super Cobra", number: "1234", scale: "1:72")
        try context.save()

        try importer.importCSV(Self.scalemates)

        #expect(first.pricePaid == 30)
        #expect(second.pricePaid == Decimal(string: "18.5"))
    }

    @Test func aScalematesImportKeepsWhatOnlyBenchBookHas() throws {
        let kit = try addKit("Airfix", "Spitfire Mk.I", number: "A05126", scale: "1:48")
        kit.status = .wip
        kit.stars = 4
        kit.notes = "Cockpit done"
        kit.isForSale = true
        kit.salePrice = 40
        try context.save()

        try importer.importCSV(Self.scalemates)

        #expect(kit.status == .wip && kit.stars == 4 && kit.notes == "Cockpit done")
        #expect(kit.isForSale && kit.salePrice == 40)
    }

    @Test func matchesByScalematesAddressWhenNumbersDiffer() throws {
        var draft = KitDraft()
        draft.brand = "Italeri"
        draft.name = "Cobra"
        draft.link = "https://scalemates.com/kits/italeri-1234-ah-1w-super-cobra--100001/"
        let kit = try service.create(from: draft)

        try importer.importCSV(Self.scalemates)

        #expect(try kits("Italeri").count == 2)
        #expect(kit.number == "1234")
    }

    @Test func rowsWithoutABrandOrNameAreReported() throws {
        let csv = """
        Brand,Title,Scale,Number
        Italeri,,1:72,1
        ,Spitfire,1:48,2
        Revell,Lancaster,1:72,04300
        """
        let summary = try importer.importCSV(csv)
        #expect(summary.added == 1)
        #expect(summary.problems.count == 2)
        #expect(summary.problems.first?.hasPrefix("Line 2:") == true)
    }

    @Test func refusesFilesWithoutTheNeededColumns() {
        #expect(throws: KitCSVImporter.ImportError.missingColumns(["Title"])) {
            try importer.importCSV("Brand,Scale\nItaleri,1:72")
        }
        #expect(throws: KitCSVImporter.ImportError.empty) {
            try importer.importCSV("Brand,Title")
        }
    }

    // MARK: BenchBook files

    private func makeEveryKindOfKit() async throws -> [Kit] {
        var details = KitDraft()
        details.brand = "Italeri"
        details.name = "Super Cobra, \"Marines\""
        details.scale = "1:72"
        details.number = "01234"
        details.link = "https://www.scalemates.com/kits/italeri-1234--1"
        details.pricePaid = "18.5"
        details.isForSale = true
        details.salePrice = "25"
        details.stars = 3
        details.status = .opened
        details.notes = "Line one\nLine two"
        let full = try service.create(from: details)

        var wanted = KitDraft()
        wanted.brand = "Revell"
        wanted.name = "Lancaster"
        wanted.isOwned = false
        let notOwned = try service.create(from: wanted)
        return [full, notOwned]
    }

    @Test func anExportImportsBackUnchanged() async throws {
        let original = try await makeEveryKindOfKit()
        let csv = KitCSVExporter.csv(KitCSVExporter.rows(for: original), options: .init(includesNotes: true))
        #expect(csv.contains(",18.50,"))

        let other = try Fixtures.makeInMemoryContainer()
        let summary = try KitCSVImporter(context: other.mainContext).importCSV(csv)
        #expect(summary.added == 2)
        #expect(summary.problems.isEmpty)

        let imported = try other.mainContext.fetch(FetchDescriptor<Kit>())
        let sortByID: (KitCSVExporter.Row, KitCSVExporter.Row) -> Bool = { $0.id.uuidString < $1.id.uuidString }
        var expected = KitCSVExporter.rows(for: original).sorted(by: sortByID)
        var actual = KitCSVExporter.rows(for: imported).sorted(by: sortByID)
        for index in expected.indices { expected[index].createdAt = .distantPast }
        for index in actual.indices { actual[index].createdAt = .distantPast }
        #expect(actual == expected)
    }

    @Test func aBenchBookFileMatchesEntriesByID() async throws {
        let original = try await makeEveryKindOfKit()
        let csv = KitCSVExporter.csv(KitCSVExporter.rows(for: original), options: .init(includesNotes: true))
        original[0].status = .built
        original[0].notes = nil
        original[1].isOwned = true
        try context.save()

        let summary = try importer.importCSV(csv)

        #expect(summary.added == 0)
        #expect(summary.updated == 2)
        #expect(original[0].status == .opened)
        #expect(original[0].notes == "Line one\nLine two")
        #expect(!original[1].isOwned)
        #expect(try kits().count == 2)
    }

    @Test func badStatusesAndRatingsAreReportedAndTheRestImported() throws {
        let kit = try addKit("Italeri", "Super Cobra", number: "1234", scale: "1:72")
        kit.status = .wip
        kit.stars = 2
        try context.save()
        let csv = """
        BenchBook ID,Brand,Title,Status,Rating,Price
        \(kit.id.uuidString),Italeri,Super Cobra,Painted,7,20
        ,Revell,Lancaster,built,5,
        """
        let summary = try importer.importCSV(csv)

        #expect(summary.problems.count == 2)
        #expect(kit.status == .wip && kit.stars == 2)
        #expect(kit.pricePaid == 20)
        let lancaster = try #require(try kits("Revell").first)
        #expect(lancaster.status == .built && lancaster.stars == 5)
        #expect(lancaster.isOwned)
    }

    @Test func notesAreLeftOutUnlessAskedFor() async throws {
        let kits = try await makeEveryKindOfKit()
        let csv = KitCSVExporter.csv(KitCSVExporter.rows(for: kits))
        #expect(!csv.contains("Notes"))
        #expect(!csv.contains("Line one"))
        #expect(csv.hasPrefix("BenchBook ID,Brand,Title,Scale,Number,Type,Price,Link,Owned,Status,Rating,For Sale,Sale Price\r\n"))
    }
}

@MainActor
struct KitImportSummaryTests {
    @Test func describesWhatAnImportDid() {
        var summary = KitCSVImporter.Summary()
        summary.added = 3
        summary.updated = 1
        summary.unchanged = 110
        summary.skipped = [("Markings (Decals)", 22), ("Detail and Conversion sets", 5)]
        #expect(KitCatalogueView.importTitle(summary) == "Added 3 Kits and Updated 1")
        #expect(KitCatalogueView.importMessage(summary) == """
        Already in your catalogue: 110.
        27 rows skipped that aren't kits: Markings (Decals) 22, Detail and Conversion sets 5.
        """)

        #expect(KitCatalogueView.importTitle(KitCSVImporter.Summary()) == "No Kits Added")
        summary.added = 0
        #expect(KitCatalogueView.importTitle(summary) == "Updated 1 Kit")
        summary.updated = 0
        summary.added = 1
        #expect(KitCatalogueView.importTitle(summary) == "Added 1 Kit")
    }
}

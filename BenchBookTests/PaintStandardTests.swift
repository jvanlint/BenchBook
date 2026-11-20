import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct PaintStandardParserTests {
    private func parsed(_ text: String) -> [String]? {
        PaintStandardParser.parse(text).map { [$0.system.rawValue, $0.code] }
    }

    @Test func clearPrefixesBecomeTheirSystem() {
        #expect(parsed("FS 36270") == ["fs595", "36270"])
        #expect(parsed("FS36270") == ["fs595", "36270"])
        #expect(parsed("fs-36270") == ["fs595", "36270"])
        #expect(parsed("FS595 36270") == ["fs595", "36270"])
        #expect(parsed("FS 595 36270") == ["fs595", "36270"])
        #expect(parsed("AMS-STD-595 36270") == ["fs595", "36270"])
        #expect(parsed("RAL 7021") == ["ral", "7021"])
        #expect(parsed("RLM76") == ["rlm", "76"])
        #expect(parsed("BS 640") == ["bs381c", "640"])
        #expect(parsed("BSC 637") == ["bs381c", "637"])
        #expect(parsed("BS 381C 637") == ["bs381c", "637"])
        #expect(parsed("ANA 613") == ["ana", "613"])
        #expect(parsed("MAP Sky") == ["map", "Sky"])
        #expect(parsed("  RLM 02 ") == ["rlm", "02"])
        #expect(parsed("RLM") == ["rlm", ""])
    }

    /// IJN and IJA say which service, so the code keeps them.
    @Test func japaneseStandardsKeepTheirPrefix() {
        #expect(parsed("IJN J3") == ["ijn", "IJN J3"])
        #expect(parsed("IJA #7") == ["ijn", "IJA #7"])
    }

    @Test func otherTextIsKeptWhole() {
        #expect(parsed("FS 36375 / BS 637") == ["multiple", "FS 36375 / BS 637"])
        #expect(parsed("RLM 74, RLM 75") == ["multiple", "RLM 74, RLM 75"])
        #expect(parsed("Humbrol 28") == ["custom", "Humbrol 28"])
        #expect(parsed("Maple") == ["custom", "Maple"])
        #expect(parsed("Ralph's grey") == ["custom", "Ralph's grey"])
        #expect(parsed("36270") == ["custom", "36270"])
        #expect(parsed("  ") == nil)
    }

    @Test func showsWithItsPrefix() {
        #expect(PaintStandard(system: .fs595, code: "36270").displayText == "FS 36270")
        #expect(PaintStandard(system: .bs381c, code: "640").displayText == "BS 640")
        #expect(PaintStandard(system: .ships2, code: "5-N").displayText == "5-N")
        #expect(PaintStandard(system: .multiple, code: "FS 36375 / BS 637").displayText == "FS 36375 / BS 637")
        #expect(PaintStandard(system: .rlm, code: " ").displayText == "RLM")
        // An unknown stored system still shows its code.
        #expect(PaintStandard(systemRaw: "future", code: "X1")?.displayText == "X1")
        #expect(PaintStandard(systemRaw: "", code: "36270") == nil)
    }

    @Test func matchesWhateverTheSpelling() {
        let fs = PaintStandard(system: .fs595, code: "36270")
        #expect(PaintStandard(system: .fs595, code: "36 270").matchKey == fs.matchKey)
        #expect(PaintStandard(system: .custom, code: "FS-36270").matchKey == PaintStandard(system: .custom, code: "fs 36270").matchKey)
        #expect(PaintStandard(system: .fs595, code: "36375").matchKey != fs.matchKey)
        #expect(PaintStandard(system: .rlm, code: "36270").matchKey != fs.matchKey)
    }

    @Test func readsMatchAndTypeNames() {
        #expect(PaintMatch(text: "Exact match") == .exact)
        #expect(PaintMatch(text: "closest") == .closest)
        #expect(PaintMatch(text: "No Match") == .noMatch)
        #expect(PaintMatch(text: "none") == .noMatch)
        #expect(PaintMatch(text: "Nearly") == nil)
        #expect(PaintType(text: "lacquer") == .lacquer)
        #expect(PaintType(text: "Alcohol-compatible acrylic") == .alcoholAcrylic)
        #expect(PaintType(text: "waterAcrylic") == .waterAcrylic)
        #expect(PaintType(text: "Gouache") == nil)
    }
}

@MainActor
struct PaintStandardMigrationTests {
    private typealias Old = BenchBookSchemaV4

    @Test func standardsAreSplitAndNothingIsLost() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")
        do {
            let schema = Schema(versionedSchema: Old.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let context = container.mainContext
            func paint(_ code: String, _ standard: String) -> Old.Paint {
                let paint = Old.Paint(brand: "Mr. Color", code: code, identityKey: code)
                paint.standardCode = standard
                context.insert(paint)
                return paint
            }
            let grey = paint("C307", "FS 36320")
            _ = paint("C117", "FS 34102 / RAL 6003")
            _ = paint("C1", "Humbrol 28")
            _ = paint("C2", "")
            _ = paint("C3", "IJN J3")
            let project = Old.Project(name: "F-16C")
            context.insert(project)
            context.insert(Old.ProjectPaint(project: project, paint: grey, standard: "FS36320", usedFor: "upper"))
            context.insert(Old.ProjectPaint(project: project, standard: "RLM 76"))
            context.insert(Old.ProjectPaint(project: project, paint: grey))
            try context.save()
        }

        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let context = container.mainContext
        let paints = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Paint>()).map { ($0.code, $0) })
        #expect(paints["C307"]?.standard == PaintStandard(system: .fs595, code: "36320"))
        #expect(paints["C117"]?.standard == PaintStandard(system: .multiple, code: "FS 34102 / RAL 6003"))
        #expect(paints["C1"]?.standard == PaintStandard(system: .custom, code: "Humbrol 28"))
        #expect(paints["C2"]?.standard == nil)
        #expect(paints["C3"]?.standardText == "IJN J3")
        #expect(paints.values.allSatisfy { $0.match == nil && $0.type == nil })

        let rows = try context.fetch(FetchDescriptor<ProjectPaint>())
        #expect(Set(rows.map(\.standardText)) == ["FS 36320", "RLM 76", ""])
        let upper = try #require(rows.first { $0.usedFor == "upper" })
        #expect(upper.standard == "36320")
        #expect(try #require(upper.selectedPaint).hasStandard(try #require(upper.guideStandard)))
    }
}

@MainActor
struct PaintStandardCSVTests {
    @Test func readsBenchBookColumns() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let csv = """
        Brand,Code,Standard,Standard Code,Match,Type
        Mr. Color,C307,FS 595,36320,Exact match,Lacquer
        Tamiya,XF-19,fs595,36173,closest,alcoholAcrylic
        AK,RC1,FS,34102,,
        Vallejo,70.1,Humbrol,28,,
        Revell,32,,,Exact match,Enamel
        Mr. Hobby,H1,RLM,76,Nearly,Gouache
        """
        let summary = try PaintCSVImporter(context: container.mainContext).importCSV(csv)
        #expect(summary.added == 6)
        #expect(summary.problems.count == 2)

        let paints = Dictionary(uniqueKeysWithValues: try container.mainContext.fetch(FetchDescriptor<Paint>()).map { ($0.code, $0) })
        #expect(paints["C307"]?.standardText == "FS 36320")
        #expect(paints["C307"]?.match == .exact)
        #expect(paints["C307"]?.type == .lacquer)
        #expect(paints["XF-19"]?.standard?.system == .fs595)
        #expect(paints["XF-19"]?.match == .closest)
        #expect(paints["XF-19"]?.type == .alcoholAcrylic)
        #expect(paints["RC1"]?.standardText == "FS 34102")
        #expect(paints["70.1"]?.standard == PaintStandard(system: .custom, code: "Humbrol 28"))
        // A match needs a standard.
        #expect(paints["32"]?.standard == nil && paints["32"]?.match == nil)
        #expect(paints["32"]?.type == .enamel)
        #expect(paints["H1"]?.match == nil && paints["H1"]?.type == nil)
    }

    @Test func oldStandardColumnIsSplit() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let csv = """
        Brand,Code,Standard
        Mr. Color,C307,FS 36320
        AK,RC1,RLM 74 / RLM 75
        """
        _ = try PaintCSVImporter(context: container.mainContext).importCSV(csv)
        let paints = Dictionary(uniqueKeysWithValues: try container.mainContext.fetch(FetchDescriptor<Paint>()).map { ($0.code, $0) })
        #expect(paints["C307"]?.standard == PaintStandard(system: .fs595, code: "36320"))
        #expect(paints["RC1"]?.standard?.system == .multiple)
    }
}

@MainActor
struct PaintUnknownValueTests {
    /// A value from a newer version is kept when the paint is edited.
    @Test func editingKeepsUnknownValues() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let service = PaintService(context: container.mainContext)
        var draft = PaintDraft()
        draft.brand = "Tamiya"
        draft.code = "XF-1"
        let paint = try service.createPaint(from: draft)
        paint.standardSystemRaw = "future"
        paint.standardCode = "X1"
        paint.matchRaw = "nearly"
        paint.typeRaw = "gouache"

        var edit = PaintDraft(paint: paint)
        #expect(edit.standardSystem == .custom && edit.match == nil && edit.type == nil)
        edit.name = "Flat Black"
        try service.update(paint, from: edit)
        #expect([paint.standardSystemRaw, paint.standardCode, paint.matchRaw, paint.typeRaw]
                == ["future", "X1", "nearly", "gouache"])

        edit.type = .lacquer
        try service.update(paint, from: edit)
        #expect(paint.typeRaw == "lacquer" && paint.standardSystemRaw == "future")
    }
}

struct PaintTypeFilterTests {
    @Test func showsOneTypeOrNone() {
        let lacquers = PaintFilter(type: .type(.lacquer))
        #expect(lacquers.isActive)
        #expect(lacquers.includes(brand: "Mr. Color", range: "", type: .lacquer, isOwned: false))
        #expect(!lacquers.includes(brand: "Tamiya", range: "", type: .enamel, isOwned: false))
        #expect(!lacquers.includes(brand: "Tamiya", range: "", type: nil, isOwned: false))

        let notSet = PaintFilter(type: .notSet)
        #expect(notSet.includes(brand: "Tamiya", range: "", type: nil, isOwned: false))
        #expect(!notSet.includes(brand: "Tamiya", range: "", type: .lacquer, isOwned: false))

        #expect(PaintFilter().includes(brand: "Tamiya", range: "", type: .oil, isOwned: false))
    }
}

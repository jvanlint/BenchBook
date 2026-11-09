import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct PaintCSVExportTests {
    private func row(_ brand: String, _ code: String, name: String = "", standard: String = "",
                     hex: String? = nil, owned: Bool = false, notes: String? = nil) -> PaintCSVExporter.Row {
        PaintCSVExporter.Row(brand: brand, range: "Acrylic", code: code, name: name, standard: standard,
                             swatchHex: hex, isOwned: owned, notes: notes)
    }

    @Test func writesSortedQuotedRowsWithOptionalColumns() {
        let rows = [
            row("Tamiya", "XF-10", name: "Flat Brown"),
            row("Tamiya", "XF-2", name: "Flat White", hex: "#F2F2F2", owned: true, notes: "Thin 1:1, \"X-20A\""),
            row("AK", "RC001", name: "White, gloss", standard: "FS 37875 / RAL 9010"),
        ]

        #expect(PaintCSVExporter.csv(rows) == """
        Brand,Range,Code,Name,FS/RLM,Colour\r
        AK,Acrylic,RC001,"White, gloss",FS 37875 / RAL 9010,\r
        Tamiya,Acrylic,XF-2,Flat White,,#F2F2F2\r
        Tamiya,Acrylic,XF-10,Flat Brown,,\r

        """)

        let everything = PaintCSVExporter.csv(rows, options: .init(includesOwnership: true, includesNotes: true))
        let lines = everything.components(separatedBy: "\r\n")
        #expect(lines[0] == "Brand,Range,Code,Name,FS/RLM,Colour,Owned,Notes")
        #expect(lines[2] == #"Tamiya,Acrylic,XF-2,Flat White,,#F2F2F2,yes,"Thin 1:1, ""X-20A""""#)
        #expect(lines[3] == "Tamiya,Acrylic,XF-10,Flat Brown,,,,")
    }

    /// The file imports into another catalogue with the same paints.
    @Test func roundTripsThroughTheImporter() throws {
        let source = try Fixtures.makeInMemoryContainer()
        let service = PaintService(context: source.mainContext)
        var draft = PaintDraft()
        draft.brand = "Tamiya"
        draft.range = "Acrylic XF"
        draft.code = "XF-54"
        draft.name = "Dark Sea Grey"
        draft.standardCode = "BS 640 / FS 36173"
        draft.swatchHex = "#5B6066"
        draft.notes = "Line one\nline two, with \"quotes\""
        draft.isOwned = true
        try service.createPaint(from: draft)
        draft = PaintDraft()
        draft.brand = "Mr. Color"
        draft.code = "C307"
        try service.createPaint(from: draft)

        let paints = try source.mainContext.fetch(FetchDescriptor<Paint>())
        let csv = PaintCSVExporter.csv(PaintCSVExporter.rows(for: paints),
                                       options: .init(includesOwnership: true, includesNotes: true))

        let target = try Fixtures.makeInMemoryContainer()
        let summary = try PaintCSVImporter(context: target.mainContext).importCSV(csv)
        #expect(summary == PaintCSVImporter.Summary(added: 2))

        let imported = try target.mainContext.fetch(FetchDescriptor<Paint>())
        func describe(_ paint: Paint) -> [String] {
            [paint.brand, paint.range, paint.code, paint.name, paint.standardCode,
             paint.swatchHex ?? "", paint.notes ?? "", paint.isOwned ? "owned" : ""]
        }
        let sortKey: (Paint) -> String = { $0.identityKey }
        #expect(imported.sorted { sortKey($0) < sortKey($1) }.map(describe)
                == paints.sorted { sortKey($0) < sortKey($1) }.map(describe))

        // Without the personal columns, nothing is owned and there are no notes.
        let shared = try Fixtures.makeInMemoryContainer()
        _ = try PaintCSVImporter(context: shared.mainContext).importCSV(PaintCSVExporter.csv(PaintCSVExporter.rows(for: paints)))
        let sharedPaints = try shared.mainContext.fetch(FetchDescriptor<Paint>())
        #expect(sharedPaints.count == 2)
        #expect(sharedPaints.allSatisfy { !$0.isOwned && $0.notes == nil })
        #expect(sharedPaints.contains { $0.standardCode == "BS 640 / FS 36173" && $0.swatchHex == "#5B6066" })
    }

    @Test func filename() throws {
        let date = try Date("2026-11-09T12:00:00Z", strategy: .iso8601)
        #expect(PaintCSVExporter.filename(on: date) == "BenchBook Paints 2026-11-09")
    }
}

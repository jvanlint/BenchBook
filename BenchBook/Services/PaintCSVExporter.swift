import Foundation

/// Writes paints as a CSV file that `PaintCSVImporter` reads back, so a
/// catalogue can be shared with another BenchBook.
nonisolated enum PaintCSVExporter {
    struct Row: Equatable {
        var brand: String
        var range: String
        var code: String
        var name: String
        var standard: String
        var swatchHex: String?
        var isOwned: Bool
        var notes: String?
    }

    struct Options: Equatable {
        /// Ownership and notes are personal, so they're left out unless asked for.
        var includesOwnership = false
        var includesNotes = false
    }

    @MainActor
    static func rows(for paints: [Paint]) -> [Row] {
        paints.map { paint in
            Row(brand: paint.brand, range: paint.range, code: paint.code, name: paint.name,
                standard: paint.standardCode, swatchHex: paint.swatchHex, isOwned: paint.isOwned, notes: paint.notes)
        }
    }

    /// Sorted by brand, range and code, with a header row of the importer's
    /// column names. Lines end in CRLF, as spreadsheets expect.
    static func csv(_ rows: [Row], options: Options = Options()) -> String {
        var header = ["Brand", "Range", "Code", "Name", "FS/RLM", "Colour"]
        if options.includesOwnership { header.append("Owned") }
        if options.includesNotes { header.append("Notes") }

        let sorted = rows.sorted { a, b in
            for (x, y) in [(a.brand, b.brand), (a.range, b.range), (a.code, b.code)] {
                let result = x.localizedStandardCompare(y)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
        let lines = [header] + sorted.map { row in
            var fields = [row.brand, row.range, row.code, row.name, row.standard, row.swatchHex ?? ""]
            if options.includesOwnership { fields.append(row.isOwned ? "yes" : "") }
            if options.includesNotes { fields.append(row.notes ?? "") }
            return fields
        }
        return lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// e.g. "BenchBook Paints 2026-11-09" (the Save dialog adds .csv).
    static func filename(on date: Date = .now) -> String {
        String(localized: "BenchBook Paints \(date.formatted(.iso8601.year().month().day()))")
    }

    /// Quotes fields with commas, quotes, line breaks or edge spaces.
    private static func escape(_ field: String) -> String {
        let needsQuotes = field.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || field.first?.isWhitespace == true || field.last?.isWhitespace == true
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

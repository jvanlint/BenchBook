import Foundation

/// Writes kits as a CSV file that `KitCSVImporter` reads back unchanged:
/// one row per kit entry. Pictures aren't included; backups have them.
nonisolated enum KitCSVExporter {
    struct Row: Equatable {
        var id: UUID
        var brand: String
        var name: String
        var scale: String?
        var number: String?
        var pricePaid: Decimal?
        var link: URL?
        var isOwned: Bool
        var statusRaw: String
        var rating: Int?
        var isForSale: Bool
        var salePrice: Decimal?
        var notes: String?
        var createdAt: Date
    }

    struct Options: Equatable {
        /// Notes are personal, so they're left out unless asked for.
        var includesNotes = false
    }

    static let header = [
        "BenchBook ID", "Brand", "Title", "Scale", "Number", "Type", "Price", "Link",
        "Owned", "Status", "Rating", "For Sale", "Sale Price",
    ]

    @MainActor
    static func rows(for kits: [Kit]) -> [Row] {
        kits.map { kit in
            Row(id: kit.id, brand: kit.brand, name: kit.name, scale: kit.scale, number: kit.number,
                pricePaid: kit.pricePaid, link: kit.link, isOwned: kit.isOwned, statusRaw: kit.statusRaw,
                rating: kit.stars, isForSale: kit.isForSale, salePrice: kit.salePrice, notes: kit.notes,
                createdAt: kit.createdAt)
        }
    }

    /// Sorted by brand, number and scale, then the order they were added.
    /// Prices use a full stop whatever the Mac's region. Lines end in CRLF,
    /// as spreadsheets expect.
    static func csv(_ rows: [Row], options: Options = Options()) -> String {
        let header = header + (options.includesNotes ? ["Notes"] : [])
        let sorted = rows.sorted { a, b in
            for (x, y) in [(a.brand, b.brand), (a.number ?? "", b.number ?? ""), (a.scale ?? "", b.scale ?? "")] {
                let result = x.localizedStandardCompare(y)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return a.createdAt < b.createdAt
        }
        let lines = [header] + sorted.map { row in
            var fields = [
                row.id.uuidString, row.brand, row.name, row.scale ?? "", row.number ?? "", KitCSVImporter.kitType,
                row.pricePaid.map(KitPrice.plain) ?? "", row.link?.absoluteString ?? "",
                row.isOwned ? "Yes" : "", status(row.statusRaw), row.rating.map(String.init) ?? "",
                row.isForSale ? "Yes" : "", row.salePrice.map(KitPrice.plain) ?? "",
            ]
            if options.includesNotes { fields.append(row.notes ?? "") }
            return fields
        }
        return lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// e.g. "BenchBook Kits 2026-11-19" (the Save dialog adds .csv).
    static func filename(on date: Date = .now) -> String {
        String(localized: "BenchBook Kits \(date.formatted(.iso8601.year().month().day()))")
    }

    /// BNIB, Opened, WIP or Built. An unknown stored status is written as
    /// it is, and reported if the file is imported.
    private static func status(_ raw: String) -> String {
        switch raw {
        case "bnib": "BNIB"
        case "opened": "Opened"
        case "wip": "WIP"
        case "built": "Built"
        default: raw
        }
    }

    /// Quotes fields with commas, quotes, line breaks or edge spaces.
    private static func escape(_ field: String) -> String {
        let needsQuotes = field.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || field.first?.isWhitespace == true || field.last?.isWhitespace == true
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

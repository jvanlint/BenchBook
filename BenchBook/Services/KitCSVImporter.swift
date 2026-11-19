import Foundation
import SwiftData

/// Imports kits from a CSV file with a header row: a Scalemates stash
/// export, or BenchBook's own export (which has a "BenchBook ID" column).
/// Columns are found by name, in any order and case; others are ignored.
///
/// Each row is one physical kit. Scalemates rows have no ID, so they're
/// matched to the library by count: three rows for a kit the library has
/// once adds two. BenchBook rows match their entry by ID.
struct KitCSVImporter {
    struct Summary: Equatable {
        var added = 0
        /// Existing entries the file changed.
        var updated = 0
        /// Rows for entries the library already has as they are.
        var unchanged = 0
        /// Rows that aren't kits, by their Type, most first.
        var skipped: [(type: String, count: Int)] = []
        /// "Line 7: a kit needs a brand and a name." etc.
        var problems: [String] = []

        var skippedCount: Int { skipped.reduce(0) { $0 + $1.count } }

        static func == (lhs: Summary, rhs: Summary) -> Bool {
            lhs.added == rhs.added && lhs.updated == rhs.updated && lhs.unchanged == rhs.unchanged
                && lhs.skipped.map(\.type) == rhs.skipped.map(\.type) && lhs.skipped.map(\.count) == rhs.skipped.map(\.count)
                && lhs.problems == rhs.problems
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case empty
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .empty:
                String(localized: "The file has no rows to import.")
            case .missingColumns(let names):
                String(localized: "The file's first row must name the columns. Missing: \(names.formatted(.list(type: .and))).")
            }
        }
    }

    enum Column: CaseIterable {
        case id, brand, name, scale, number, type, price, link, owned, status, rating, forSale, salePrice, notes

        var headers: Set<String> {
            switch self {
            case .id: ["benchbook id"]
            case .brand: ["brand", "manufacturer"]
            case .name: ["title", "name"]
            case .scale: ["scale"]
            case .number: ["number", "kit number"]
            case .type: ["type"]
            case .price: ["price", "price paid"]
            case .link: ["link", "url"]
            case .owned: ["owned"]
            case .status: ["status"]
            case .rating: ["rating"]
            case .forSale: ["for sale"]
            case .salePrice: ["sale price"]
            case .notes: ["notes"]
            }
        }
    }

    /// The Scalemates type of a kit. Other rows are decals, detail sets and so on.
    static let kitType = "Static model kits"

    let context: ModelContext

    /// One kit row, read and checked.
    private struct Row {
        let line: Int
        var id: UUID?
        var brand: String
        var name: String
        var scale: String?
        var number: String?
        var link: URL?
        var price: Decimal?
        // Only in BenchBook's own files.
        var isOwned: Bool?
        var status: KitStatus?
        var rating: Int??
        var isForSale: Bool?
        var salePrice: Decimal?
        var notes: String??
    }

    @discardableResult
    func importCSV(_ text: String) throws -> Summary {
        let table = CSVParser.parse(text)
        guard let header = table.first else { throw ImportError.empty }

        var columns: [Column: Int] = [:]
        for (index, title) in header.fields.enumerated() {
            let key = title.trimmingCharacters(in: .whitespaces).lowercased()
            if let column = Column.allCases.first(where: { $0.headers.contains(key) }), columns[column] == nil {
                columns[column] = index
            }
        }
        let missing = [(Column.brand, "Brand"), (Column.name, "Title")].filter { columns[$0.0] == nil }.map(\.1)
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }
        guard table.count > 1 else { throw ImportError.empty }

        let isBenchBookFile = columns[.id] != nil
        var summary = Summary()
        var skipped: [String: (name: String, count: Int)] = [:]
        var rows: [Row] = []

        for record in table.dropFirst() {
            func value(_ column: Column) -> String? {
                guard let index = columns[column], record.fields.indices.contains(index) else { return nil }
                return record.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let line = record.line

            if let type = value(.type)?.trimmedOrNil, type.caseInsensitiveCompare(Self.kitType) != .orderedSame {
                skipped[type.lowercased(), default: (type, 0)].count += 1
                continue
            }
            guard let brand = value(.brand)?.trimmedOrNil, let name = value(.name)?.trimmedOrNil else {
                summary.problems.append(String(localized: "Line \(line): a kit needs a brand and a name."))
                continue
            }
            var row = Row(line: line, brand: brand, name: name,
                          scale: value(.scale)?.trimmedOrNil, number: value(.number)?.trimmedOrNil)
            row.id = value(.id).flatMap(UUID.init(uuidString:))

            if let text = value(.link)?.trimmedOrNil {
                if let url = WebAddress.parse(text) {
                    row.link = url
                } else {
                    summary.problems.append(String(localized: "Line \(line): “\(text)” isn't a web address, so the link was left out."))
                }
            }
            row.price = price(value(.price), line: line, zeroIsBlank: !isBenchBookFile, problems: &summary.problems)
            row.salePrice = price(value(.salePrice), line: line, zeroIsBlank: false, problems: &summary.problems)

            if isBenchBookFile {
                if let owned = value(.owned) { row.isOwned = Self.isYes(owned) }
                if let forSale = value(.forSale) { row.isForSale = Self.isYes(forSale) }
                if let notes = value(.notes) { row.notes = .some(notes.trimmedOrNil) }
                if let text = value(.status)?.trimmedOrNil {
                    // The file's words are English whatever the Mac's language.
                    if let status = KitStatus(rawValue: text.lowercased()) {
                        row.status = status
                    } else {
                        summary.problems.append(String(localized: "Line \(line): “\(text)” isn't a status. Use BNIB, Opened, WIP or Built."))
                    }
                }
                if let text = value(.rating) {
                    if text.isEmpty {
                        row.rating = .some(nil)
                    } else if let stars = Int(text), Kit.ratingRange.contains(stars) {
                        row.rating = .some(stars)
                    } else {
                        summary.problems.append(String(localized: "Line \(line): “\(text)” isn't a rating from 1 to 5."))
                    }
                }
            }
            rows.append(row)
        }

        summary.skipped = skipped.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (type: $0.name, count: $0.count) }

        let kits = try context.fetch(FetchDescriptor<Kit>(sortBy: [SortDescriptor(\.createdAt)]))
        if isBenchBookFile {
            importBenchBookRows(rows, into: kits, summary: &summary)
        } else {
            importScalematesRows(rows, into: kits, summary: &summary)
        }

        // One save for the whole file: it all imports, or nothing does.
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return summary
    }

    // MARK: Scalemates

    /// Rows for the same kit are compared with the library's entries for it:
    /// owned entries count first, then entries that aren't owned become owned,
    /// then new entries are added for any rows left.
    private func importScalematesRows(_ rows: [Row], into kits: [Kit], summary: inout Summary) {
        var groups: [[Row]] = []
        for row in rows {
            if let index = groups.firstIndex(where: { Self.isSame(row, $0[0]) }) {
                groups[index].append(row)
            } else {
                groups.append([row])
            }
        }

        var claimed = Set<PersistentIdentifier>()
        for group in groups {
            let first = group[0]
            let matches = kits.filter { kit in
                !claimed.contains(kit.persistentModelID) && Self.isSame(first, kit)
            }
            claimed.formUnion(matches.map(\.persistentModelID))
            let owned = matches.filter(\.isOwned)
            let notOwned = matches.filter { !$0.isOwned }

            var changed = Set<PersistentIdentifier>()
            // The details on every entry for the kit follow the file.
            for kit in matches where Self.applyDetails(first, to: kit) {
                changed.insert(kit.persistentModelID)
            }

            var entries = owned
            for kit in notOwned.prefix(max(group.count - owned.count, 0)) {
                kit.isOwned = true
                changed.insert(kit.persistentModelID)
                entries.append(kit)
            }
            while entries.count < group.count {
                let kit = Kit(brand: first.brand, name: first.name, scale: first.scale, number: first.number)
                kit.link = first.link
                context.insert(kit)
                entries.append(kit)
                summary.added += 1
            }

            // Prices only fill entries that have none, row by row.
            let existing = Set(matches.map(\.persistentModelID))
            for (row, kit) in zip(group, entries) where kit.pricePaid == nil {
                guard let price = row.price else { continue }
                kit.pricePaid = price
                if existing.contains(kit.persistentModelID) { changed.insert(kit.persistentModelID) }
            }

            for kit in matches where changed.contains(kit.persistentModelID) { kit.updatedAt = .now }
            summary.updated += changed.count
            // Rows whose entry was already there, just as the file has it.
            summary.unchanged += entries.prefix(group.count).filter {
                existing.contains($0.persistentModelID) && !changed.contains($0.persistentModelID)
            }.count
        }
    }

    /// Updates brand, name, scale, number and link from the file. Blank
    /// values in the file never clear the entry's. Returns whether it changed.
    private static func applyDetails(_ row: Row, to kit: Kit) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Kit, T>, _ value: T) {
            if kit[keyPath: keyPath] != value {
                kit[keyPath: keyPath] = value
                changed = true
            }
        }
        set(\.brand, row.brand)
        set(\.name, row.name)
        if let scale = row.scale { set(\.scale, scale) }
        if let number = row.number { set(\.number, number) }
        if let link = row.link { set(\.link, link) }
        return changed
    }

    // MARK: BenchBook

    /// Each row matches its entry by BenchBook ID and sets every field the
    /// file has. Rows without a known ID are added.
    private func importBenchBookRows(_ rows: [Row], into kits: [Kit], summary: inout Summary) {
        var byID = Dictionary(kits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if let id = row.id, let kit = byID[id] {
                if Self.applyAll(row, to: kit) {
                    kit.updatedAt = .now
                    summary.updated += 1
                } else {
                    summary.unchanged += 1
                }
            } else {
                let kit = Kit(id: row.id ?? UUID(), brand: row.brand, name: row.name)
                context.insert(kit)
                _ = Self.applyAll(row, to: kit)
                byID[kit.id] = kit
                summary.added += 1
            }
        }
    }

    private static func applyAll(_ row: Row, to kit: Kit) -> Bool {
        var changed = applyDetails(row, to: kit)
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Kit, T>, _ value: T) {
            if kit[keyPath: keyPath] != value {
                kit[keyPath: keyPath] = value
                changed = true
            }
        }
        if let isOwned = row.isOwned { set(\.isOwned, isOwned) }
        if let status = row.status { set(\.statusRaw, status.rawValue) }
        if let rating = row.rating { set(\.rating, rating) }
        if let price = row.price { set(\.pricePaid, Optional(price)) }
        if let isForSale = row.isForSale { set(\.isForSale, isForSale) }
        if let salePrice = row.salePrice { set(\.salePrice, Optional(salePrice)) }
        if let notes = row.notes { set(\.notes, notes) }
        return changed
    }

    // MARK: Helpers

    private static func isSame(_ row: Row, _ other: Row) -> Bool {
        isSame(row, (other.brand, other.name, other.number, other.scale, other.link))
    }

    private static func isSame(_ row: Row, _ kit: Kit) -> Bool {
        isSame(row, (kit.brand, kit.name, kit.number, kit.scale, kit.link))
    }

    /// The same kit, as the editor decides it. Rows with neither a number nor
    /// a Scalemates address also match on brand, name and scale, so
    /// importing such a file twice doesn't add everything again.
    private static func isSame(_ row: Row, _ other: (brand: String, name: String, number: String?, scale: String?, link: URL?)) -> Bool {
        if KitIdentity.isSameKit(brand: row.brand, number: row.number, scale: row.scale, link: row.link,
                                 as: (other.brand, other.number, other.scale, other.link)) {
            return true
        }
        let neitherIdentified = row.number == nil && other.number == nil
            && KitIdentity.scalematesKey(row.link) == nil && KitIdentity.scalematesKey(other.link) == nil
        return neitherIdentified
            && KitIdentity.fold(row.brand) == KitIdentity.fold(other.brand)
            && KitIdentity.fold(row.name) == KitIdentity.fold(other.name)
            && (KitIdentity.fold(row.scale) ?? "") == (KitIdentity.fold(other.scale) ?? "")
    }

    /// Nil for blank, and for 0 in a Scalemates file, which means not entered.
    private func price(_ text: String?, line: Int, zeroIsBlank: Bool, problems: inout [String]) -> Decimal? {
        guard let text = text?.trimmedOrNil else { return nil }
        guard let price = KitPrice.parse(text) else {
            problems.append(String(localized: "Line \(line): “\(text)” isn't a price, so it was left out."))
            return nil
        }
        return zeroIsBlank && price == 0 ? nil : price
    }

    static func isYes(_ text: String) -> Bool {
        ["yes", "y", "true", "1", "x", "✓", "✔"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

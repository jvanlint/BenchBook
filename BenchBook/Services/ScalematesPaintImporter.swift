import Foundation
import SwiftData

/// How BenchBook names a Scalemates paint company: Scalemates puts brand
/// and range together ("Vallejo Model Air"), and calls nearly everything
/// water-based "Acrylic".
nonisolated struct ScalematesCompany: Equatable, Sendable {
    var brand: String
    var range: String
    /// The type for a paint Scalemates calls "Acrylic". Nil leaves it to
    /// Scalemates' Type, or not set.
    var acrylicType: PaintType?

    /// Keyed by Scalemates' company name, folded as `PaintIdentity.words`.
    static let known: [String: ScalematesCompany] = [
        "vallejo model air": .init(brand: "Vallejo", range: "Model Air", acrylicType: .waterAcrylic),
        "vallejo model color": .init(brand: "Vallejo", range: "Model Color", acrylicType: .waterAcrylic),
        "vallejo metal color": .init(brand: "Vallejo", range: "Metallic", acrylicType: .waterAcrylic),
        "vallejo model wash": .init(brand: "Vallejo", range: "Model Wash", acrylicType: .acrylicWash),
        "vallejo game air": .init(brand: "Vallejo", range: "Game Air", acrylicType: .waterAcrylic),
        "vallejo mecha colors": .init(brand: "Vallejo", range: "Mecha Color", acrylicType: .waterAcrylic),
        "vallejo surface primer": .init(brand: "Vallejo", range: "Surface Primer", acrylicType: .polyurethane),
        "ak real colors": .init(brand: "AK Interactive", range: "Real Color", acrylicType: nil),
        "ak interactive air series": .init(brand: "AK Interactive", range: "AIR", acrylicType: .waterAcrylic),
        "ak interactive": .init(brand: "AK Interactive", range: "", acrylicType: nil),
        "mr. aqueous hobby color": .init(brand: "Mr. Hobby", range: "Aqueous Hobby Color", acrylicType: .alcoholAcrylic),
        "ammo by mig jimenez": .init(brand: "Ammo by Mig", range: "", acrylicType: .waterAcrylic),
    ]

    /// The table's entry, or the company as the brand with no range.
    static func named(_ company: String) -> (company: ScalematesCompany, isKnown: Bool) {
        if let known = known[PaintIdentity.words(company)] { return (known, true) }
        let brand = company.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (ScalematesCompany(brand: brand, range: "", acrylicType: nil), false)
    }

    /// Scalemates' Type as BenchBook's.
    func type(forScalemates text: String) -> PaintType? {
        switch PaintIdentity.words(text) {
        case "acrylic": acrylicType
        case "acrylic lacquer", "lacquer": .lacquer
        case "enamel": .enamel
        case "pigments", "pigment": .pigment
        case "oil": .oil
        default: PaintType(text: text)
        }
    }
}

/// Imports a Scalemates paint stash export (Stash › Paints › export): marks
/// the paints in it owned, adding any the catalogue doesn't have. Paints
/// already in the catalogue are only marked owned; nothing else about them
/// changes, and paints missing from the file stay as they are.
///
/// The header names ten columns, but each row has eleven values: an
/// unnamed column sits between Remaining and Link. Named columns are read by
/// their header position, and Link is the row's last value.
struct ScalematesPaintImporter {
    struct Summary: Equatable {
        var markedOwned = 0
        var added = 0
        var alreadyOwned = 0
        /// Rows for a paint already earlier in the file, e.g. a second bottle.
        var sameRows = 0
        /// "Line 7: …" etc.
        var problems: [String] = []
        /// Company names not in the table, as written in the file.
        var unknownCompanies: [String] = []
    }

    enum ImportError: LocalizedError, Equatable {
        case notScalemates
        case empty

        var errorDescription: String? {
            switch self {
            case .notScalemates: String(localized: "This isn't a Scalemates paint stash export.")
            case .empty: String(localized: "The file has no paints to import.")
            }
        }
    }

    let context: ModelContext

    func importCSV(_ text: String) throws -> Summary {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { throw ImportError.notScalemates }
        let keys = header.fields.map { PaintIdentity.words($0) }
        func column(_ name: String) -> Int? { keys.firstIndex(of: name) }
        guard let colorColumn = column("color"), let companyColumn = column("company"),
              let numberColumn = column("number")
        else { throw ImportError.notScalemates }
        let previewColumn = column("preview"), sizeColumn = column("size")
        let typeColumn = column("type"), finishColumn = column("finish")
        guard rows.count > 1 else { throw ImportError.empty }

        let service = PaintService(context: context)
        let catalogue = try context.fetch(FetchDescriptor<Paint>()).filter { !$0.isMix }
        var byBrandAndCode = Dictionary(grouping: catalogue) { Self.matchKey(brand: $0.brand, code: $0.code) }
        var summary = Summary()
        var seen = Set<String>()
        var unknown: [String: String] = [:]

        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String {
                guard let index, row.fields.indices.contains(index) else { return "" }
                return row.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let companyName = value(companyColumn)
            let code = value(numberColumn)
            guard !companyName.isEmpty, !code.isEmpty else {
                summary.problems.append(String(localized: "Line \(row.line): a paint needs a company and a number, so it was skipped."))
                continue
            }
            let (company, isKnown) = ScalematesCompany.named(companyName)
            if !isKnown { unknown[PaintIdentity.words(companyName)] = companyName }

            let key = Self.matchKey(brand: company.brand, code: code)
            guard seen.insert(key).inserted else {
                summary.sameRows += 1
                continue
            }

            if let found = byBrandAndCode[key], !found.isEmpty {
                guard let paint = Self.pick(from: found, range: company.range) else {
                    let names = found.map(\.displayName).formatted(.list(type: .and))
                    summary.problems.append(String(localized: "Line \(row.line): \(companyName) \(code) matches \(names), so none of them was marked owned."))
                    continue
                }
                if paint.isOwned {
                    summary.alreadyOwned += 1
                } else {
                    context.insert(OwnedPaint(paint: paint))
                    summary.markedOwned += 1
                }
                continue
            }

            var draft = PaintDraft()
            draft.brand = company.brand
            draft.range = company.range
            draft.code = code
            draft.name = value(colorColumn)
            draft.type = company.type(forScalemates: value(typeColumn))
            draft.isOwned = true
            let link = row.fields.last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            draft.notes = [value(finishColumn), value(sizeColumn), link.hasPrefix("http") ? link : ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let preview = value(previewColumn)
            switch Self.swatch(fromPreview: preview) {
            case .some(.some(let hex)): draft.swatchHex = hex
            case .some(.none): break
            case .none:
                summary.problems.append(String(localized: "Line \(row.line): “\(preview)” isn't a colour like 168;181;155, so no swatch was set."))
            }
            let paint = Paint(brand: "", code: "", identityKey: draft.identityKey)
            context.insert(paint)
            service.apply(draft, to: paint)
            byBrandAndCode[key] = [paint]
            summary.added += 1
        }

        summary.unknownCompanies = unknown.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // One save for the whole file: it all imports, or nothing does.
        if context.hasChanges { try service.save() }
        return summary
    }

    /// Brand and code, ignoring range, since Scalemates' ranges don't line up
    /// with the catalogue's. The code is folded as in `PaintIdentity.key`.
    static func matchKey(brand: String, code: String) -> String {
        let parts = PaintIdentity.key(brand: brand, range: "", code: code).split(separator: "|", omittingEmptySubsequences: false)
        return [parts.first, parts.last].compactMap { $0 }.joined(separator: "|")
    }

    /// The one paint, or among several the one in the table's range.
    static func pick(from paints: [Paint], range: String) -> Paint? {
        if paints.count == 1 { return paints[0] }
        let wanted = PaintIdentity.words(range)
        guard !wanted.isEmpty else { return nil }
        let inRange = paints.filter { PaintIdentity.words($0.range) == wanted }
        return inRange.count == 1 ? inRange[0] : nil
    }

    /// "168;181;155" as "#A8B59B". `.some(nil)` for no colour (";;" or
    /// empty); nil for text that isn't a colour.
    static func swatch(fromPreview text: String) -> String?? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.allSatisfy(\.isEmpty) { return .some(nil) }
        let values = parts.compactMap { Int($0) }
        guard parts.count == 3, values.count == 3, values.allSatisfy((0...255).contains) else { return nil }
        return .some(values.map { String(format: "%02X", $0) }.reduce("#", +))
    }
}

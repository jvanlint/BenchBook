import Foundation
import SwiftData

/// Reads comma-separated text: quoted fields, doubled quotes ("") inside
/// quotes, commas and line breaks inside quotes, and CRLF line endings.
nonisolated enum CSVParser {
    /// Rows of fields, with each row's starting line number (1-based).
    static func parse(_ text: String) -> [(line: Int, fields: [String])] {
        var rows: [(Int, [String])] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")).makeIterator()
        var pending: Character? = iterator.next()

        func endRow() {
            fields.append(field)
            if !(fields.count == 1 && fields[0].isEmpty) {
                rows.append((rowStart, fields))
            }
            fields = []
            field = ""
        }

        while let character = pending {
            pending = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character == "\n" { line += 1 }
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty: inQuotes = true
                case ",":
                    fields.append(field)
                    field = ""
                case "\n":
                    endRow()
                    line += 1
                    rowStart = line
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }
}

/// Imports paints from a CSV file with a header row. Recognised columns
/// (any order, any case): Brand, Range, Code, Name, Colour/Color/Hex/Swatch,
/// Owned, Notes, Match, Type, and the colour standard: BenchBook's own
/// Standard and Standard Code columns, or one column of text such as
/// "FS 36270" ("FS/RLM", or "Standard" with no Standard Code column), or
/// separate FS, RLM, BS, RAL or ANA columns. Brand and Code are required.
///
/// A row matching a paint already in the catalogue (same identity key)
/// updates it. Only cells with something in them change the paint: a blank
/// cell, or a column the file doesn't have, leaves that value as it was, so
/// a sparse file can't wipe notes or colours. Brand, range and code identify
/// the paint, so they're never changed; mixes are never matched.
struct PaintCSVImporter {
    struct Summary: Equatable {
        var added = 0
        /// Catalogue paints the file changed.
        var updated = 0
        /// Catalogue paints the file matched without changing anything.
        var unchanged = 0
        /// Later rows for a paint already earlier in the file, skipped.
        var repeated = 0
        /// "Line 7: a paint needs a brand and a code." etc.
        var problems: [String] = []
    }

    static let ownedYes: Set<String> = ["yes", "y", "true", "1", "x", "✓", "✔"]
    static let ownedNo: Set<String> = ["no", "n", "false", "0"]

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

    private enum Column: CaseIterable {
        case brand, range, code, name, swatch, owned, notes, standardCode, match, type

        var headers: Set<String> {
            switch self {
            case .brand: ["brand", "manufacturer", "maker"]
            case .range: ["range", "line", "series"]
            case .code: ["code", "number", "paint code", "ref"]
            case .name: ["name", "colour name", "color name", "paint name"]
            case .swatch: ["colour", "color", "hex", "swatch", "rgb"]
            case .owned: ["owned", "own", "have", "in stock"]
            case .notes: ["notes", "note", "comments"]
            case .standardCode: ["standard code"]
            case .match: ["match", "standard match"]
            case .type: ["type", "paint type"]
            }
        }
    }

    /// Headers for colour standard columns. A named system's bare numbers
    /// get its prefix: "36270" in an FS column becomes "FS 36270".
    static let standardHeaders: [String: String?] = [
        "fs/rlm": nil, "fs / rlm": nil, "standard": nil, "colour standard": nil,
        "color standard": nil, "standards": nil, "equivalent": nil,
        "fs": "FS", "fs code": "FS", "federal standard": "FS", "fs595": "FS", "fs 595": "FS",
        "rlm": "RLM", "rlm code": "RLM", "bs": "BS", "bs381c": "BS", "ral": "RAL", "ana": "ANA",
    ]

    let context: ModelContext

    func importCSV(_ text: String) throws -> Summary {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { throw ImportError.empty }

        var columns: [Column: Int] = [:]
        var standardColumns: [(index: Int, prefix: String?)] = []
        // With a Standard Code column, Standard names the system.
        let keys = header.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let systemIndex = keys.contains("standard code") ? keys.firstIndex(of: "standard") : nil
        for (index, key) in keys.enumerated() {
            if index == systemIndex { continue }
            if let prefix = Self.standardHeaders[key] {
                standardColumns.append((index, prefix))
                continue
            }
            if let column = Column.allCases.first(where: { $0.headers.contains(key) }), columns[column] == nil {
                columns[column] = index
            }
        }
        let missing = [(Column.brand, "Brand"), (Column.code, "Code")].filter { columns[$0.0] == nil }.map(\.1)
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }
        guard rows.count > 1 else { throw ImportError.empty }

        let service = PaintService(context: context)
        var summary = Summary()
        var seenKeys = Set<String>()

        for row in rows.dropFirst() {
            func value(_ column: Column) -> String {
                guard let index = columns[column], row.fields.indices.contains(index) else { return "" }
                return row.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var identity = PaintDraft()
            identity.brand = value(.brand)
            identity.range = value(.range)
            identity.code = value(.code)
            if identity.missingRequiredField {
                summary.problems.append(String(localized: "Line \(row.line): a paint needs a brand and a code."))
                continue
            }
            let key = identity.identityKey
            guard seenKeys.insert(key).inserted else {
                summary.repeated += 1
                continue
            }
            let existing = try service.existingPaint(identityKey: key)
            let before = existing.map { PaintDraft(paint: $0) }
            // Blank cells keep what's there: the paint's values, or a new
            // paint's empty ones.
            var draft = before ?? identity
            if let name = value(.name).trimmedOrNil { draft.name = name }
            if let notes = value(.notes).trimmedOrNil { draft.notes = notes }
            let systemText = systemIndex.flatMap { row.fields.indices.contains($0) ? row.fields[$0].trimmedOrNil : nil }
            let standardText = standardColumns.compactMap { column -> String? in
                guard row.fields.indices.contains(column.index),
                      let text = row.fields[column.index].trimmedOrNil
                else { return nil }
                guard let prefix = column.prefix, text.first?.isNumber == true else { return text }
                return "\(prefix) \(text)"
            }.joined(separator: " / ")
            let standard = systemText.map { Self.standard(system: $0, code: value(.standardCode)) }
                ?? PaintStandardParser.parse(standardText)
            if let standard {
                draft.standardSystem = standard.system
                draft.standardCode = standard.code
            }
            if let text = value(.match).trimmedOrNil, draft.standardSystem != nil {
                if let match = PaintMatch(text: text) {
                    draft.match = match
                } else {
                    summary.problems.append(String(localized: "Line \(row.line): “\(text)” isn't No match, Closest match or Exact match, so no match was set."))
                }
            }
            if let text = value(.type).trimmedOrNil {
                if let type = PaintType(text: text) {
                    draft.type = type
                } else {
                    summary.problems.append(String(localized: "Line \(row.line): “\(text)” isn't a paint type BenchBook knows, so no type was set."))
                }
            }
            if let owned = value(.owned).trimmedOrNil?.lowercased() {
                if Self.ownedYes.contains(owned) {
                    draft.isOwned = true
                } else if Self.ownedNo.contains(owned) {
                    draft.isOwned = false
                } else {
                    summary.problems.append(String(localized: "Line \(row.line): “\(value(.owned))” isn't yes or no, so ownership wasn't changed."))
                }
            }

            let swatch = value(.swatch)
            if !swatch.isEmpty {
                if let hex = SwatchColor.normalized(swatch) {
                    draft.swatchHex = hex
                } else {
                    summary.problems.append(String(localized: "Line \(row.line): “\(swatch)” isn't a colour like #4A5A6B, so no swatch was set."))
                }
            }

            if let existing {
                if draft == before {
                    summary.unchanged += 1
                } else {
                    service.apply(draft, to: existing)
                    existing.updatedAt = .now
                    summary.updated += 1
                }
                continue
            }
            let paint = Paint(brand: "", code: "", identityKey: key)
            context.insert(paint)
            service.apply(draft, to: paint)
            summary.added += 1
        }

        // One save for the whole file: it all imports, or nothing does.
        try service.save()
        return summary
    }

    /// A Standard column naming the system, e.g. "FS 595", "fs595" or "FS",
    /// with its code. A name BenchBook doesn't know becomes Custom, with the
    /// name kept in front of the code.
    static func standard(system name: String, code: String) -> PaintStandard {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.lowercased()
        if let system = PaintStandardSystem.allCases.first(where: {
            [$0.rawValue.lowercased(), $0.displayName.lowercased(), $0.englishName.lowercased()].contains(key)
        }) {
            return PaintStandard(system: system, code: code)
        }
        if let parsed = PaintStandardParser.parse(name), parsed.system != .custom, parsed.system != .multiple,
           parsed.code.isEmpty {
            return PaintStandard(system: parsed.system, code: code)
        }
        return PaintStandard(system: .custom, code: [name, code].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

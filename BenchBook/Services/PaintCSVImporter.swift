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
/// Owned, Notes, and colour standards: one "FS/RLM" (or "Standard") column,
/// or separate FS, RLM, BS, RAL or ANA columns. Brand and Code are required.
struct PaintCSVImporter {
    struct Summary: Equatable {
        var added = 0
        /// Rows matching a paint already in the catalogue (or earlier in the file).
        var duplicates = 0
        /// "Line 7: a paint needs a brand and a code." etc.
        var problems: [String] = []
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

    private enum Column: CaseIterable {
        case brand, range, code, name, swatch, owned, notes

        var headers: Set<String> {
            switch self {
            case .brand: ["brand", "manufacturer", "maker"]
            case .range: ["range", "line", "series"]
            case .code: ["code", "number", "paint code", "ref"]
            case .name: ["name", "colour name", "color name", "paint name"]
            case .swatch: ["colour", "color", "hex", "swatch", "rgb"]
            case .owned: ["owned", "own", "have", "in stock"]
            case .notes: ["notes", "note", "comments"]
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
        for (index, title) in header.fields.enumerated() {
            let key = title.trimmingCharacters(in: .whitespaces).lowercased()
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
            var draft = PaintDraft()
            draft.brand = value(.brand)
            draft.range = value(.range)
            draft.code = value(.code)
            draft.name = value(.name)
            draft.notes = value(.notes)
            draft.standardCode = standardColumns.compactMap { column -> String? in
                guard row.fields.indices.contains(column.index),
                      let text = row.fields[column.index].trimmedOrNil
                else { return nil }
                guard let prefix = column.prefix, text.first?.isNumber == true else { return text }
                return "\(prefix) \(text)"
            }.joined(separator: " / ")
            draft.isOwned = ["yes", "y", "true", "1", "x", "✓", "✔"].contains(value(.owned).lowercased())

            let swatch = value(.swatch)
            if !swatch.isEmpty {
                if let hex = SwatchColor.normalized(swatch) {
                    draft.swatchHex = hex
                } else {
                    summary.problems.append(String(localized: "Line \(row.line): “\(swatch)” isn't a colour like #4A5A6B, so no swatch was set."))
                }
            }

            if draft.missingRequiredField {
                summary.problems.append(String(localized: "Line \(row.line): a paint needs a brand and a code."))
                continue
            }
            let key = draft.identityKey
            let alreadyInCatalogue = try service.existingPaint(identityKey: key) != nil
            if seenKeys.contains(key) || alreadyInCatalogue {
                summary.duplicates += 1
                continue
            }
            seenKeys.insert(key)
            let paint = Paint(brand: "", code: "", identityKey: key)
            context.insert(paint)
            service.apply(draft, to: paint)
            summary.added += 1
        }

        // One save for the whole file: it all imports, or nothing does.
        try service.save()
        return summary
    }
}

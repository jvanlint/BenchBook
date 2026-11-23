import Foundation

/// The colour standard a paint, or a colour in a painting guide, follows.
/// Stored as the raw value, so the wording can change. `spec/behaviour.md`
/// lists the same values for Windows.
nonisolated enum PaintStandardSystem: String, CaseIterable, Identifiable, Sendable {
    case fs595
    case ral
    case rlm
    case bs381c
    case ana
    case map
    case bulletin41
    case amt
    case ijn
    case tavola10
    case raafK3
    case ships2
    case multiple
    case custom

    var id: String { rawValue }

    /// The menu name, e.g. "FS 595".
    var displayName: String {
        switch self {
        case .fs595: "FS 595"
        case .ral: "RAL"
        case .rlm: "RLM"
        case .bs381c: "BS 381C"
        case .ana: "ANA"
        case .map: "MAP"
        case .bulletin41: "Bulletin 41"
        case .amt: "AMT / A-series"
        case .ijn: "IJN / IJA"
        case .tavola10: "Tavola 10"
        case .raafK3: "RAAF K3"
        case .ships2: "SHIPS-2"
        case .multiple: String(localized: "Multiple")
        case .custom: String(localized: "Custom")
        }
    }

    /// Written to the CSV, whatever the Mac's language.
    var englishName: String {
        switch self {
        case .multiple: "Multiple"
        case .custom: "Custom"
        default: displayName
        }
    }

    /// The menu item's hint: the reference system and what it's used for.
    var subjects: String {
        switch self {
        case .fs595: String(localized: "FS 595 / AMS-STD-595: modern military aviation")
        case .ral: String(localized: "RAL Classic: German armour and military vehicles")
        case .rlm: String(localized: "RLM: WWII Luftwaffe")
        case .bs381c: String(localized: "BS 381C: British military aircraft")
        case .ana: String(localized: "ANA: WWII US aviation")
        case .map: String(localized: "MAP: WWII RAF and Fleet Air Arm")
        case .bulletin41: String(localized: "USAAF Bulletin 41: WWII US Army aircraft")
        case .amt: String(localized: "AMT / AII / A-series: Soviet WWII aviation")
        case .ijn: String(localized: "IJN / IJA: Japanese WWII aviation")
        case .tavola10: String(localized: "Tavola 10: Italian WWII aviation")
        case .raafK3: String(localized: "RAAF K3: Australian WWII aircraft")
        case .ships2: String(localized: "US Navy SHIPS-2: WWII American warships")
        case .multiple: String(localized: "More than one standard, written out, e.g. FS 36375 / BS 637")
        case .custom: String(localized: "Any other standard, written out")
        }
    }

    /// Written before the code when the standard is shown, e.g. "FS" in
    /// "FS 36270". Nil where the code says it all, such as IJN / IJA "J3"
    /// or SHIPS-2 "5-N", and for Multiple and Custom, whose text is complete.
    /// Not localized: these are the systems' own names.
    var codePrefix: String? {
        switch self {
        case .fs595: "FS"
        case .ral: "RAL"
        case .rlm: "RLM"
        case .bs381c: "BS"
        case .ana: "ANA"
        case .map: "MAP"
        case .bulletin41: "Bulletin 41"
        case .tavola10: "Tavola 10"
        case .raafK3: "K3"
        case .amt, .ijn, .ships2, .multiple, .custom: nil
        }
    }

    /// The prompt for the code field.
    var codePrompt: String {
        switch self {
        case .fs595: String(localized: "e.g. 36270")
        case .ral: String(localized: "e.g. 7021")
        case .rlm: String(localized: "e.g. 76")
        case .bs381c: String(localized: "e.g. 637")
        case .ana: String(localized: "e.g. 613")
        case .map: String(localized: "e.g. Sky")
        case .bulletin41: String(localized: "e.g. 41")
        case .amt: String(localized: "e.g. AMT-4")
        case .ijn: String(localized: "e.g. IJN J3")
        case .tavola10: String(localized: "e.g. Verde Mimetico 2")
        case .raafK3: String(localized: "e.g. 195")
        case .ships2: String(localized: "e.g. 5-N")
        case .multiple: String(localized: "e.g. FS 36375 / BS 637")
        case .custom: String(localized: "e.g. Humbrol 28")
        }
    }
}

/// A colour standard: a system and its code. Shown as "FS 36270".
nonisolated struct PaintStandard: Equatable, Sendable {
    var system: PaintStandardSystem
    var code: String

    /// Nil for no system. An unknown stored system reads as Custom, so the
    /// code still shows.
    init?(systemRaw: String, code: String) {
        guard !systemRaw.isEmpty else { return nil }
        self.init(system: PaintStandardSystem(rawValue: systemRaw) ?? .custom, code: code)
    }

    init(system: PaintStandardSystem, code: String) {
        self.system = system
        self.code = code
    }

    /// e.g. "FS 36270", "RLM 76", "J3" or "FS 36375 / BS 637". A system
    /// with no code shows its name, e.g. "RLM".
    var displayText: String {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return system.displayName }
        guard let prefix = system.codePrefix else { return code }
        return "\(prefix) \(code)"
    }

    /// For matching a paint to a guide colour, whatever the spelling:
    /// "FS 36270", "FS36270" and "fs-36270" are the same.
    var matchKey: String {
        let folded = String(displayText.lowercased().filter { $0.isLetter || $0.isNumber })
        // Multiple and Custom are matched on their text alone, so a Custom
        // "FS 36270" still finds FS 595 36270.
        switch system {
        case .multiple, .custom: return folded
        default: return system.rawValue + ":" + folded
        }
    }
}

/// Splits free text such as "FS 36270" into a system and a code, for the
/// 5.0.0 upgrade, CSV import and the old one-column standard. No text is
/// ever lost: anything not recognised is kept whole as Multiple or Custom.
nonisolated enum PaintStandardParser {
    /// Recognised prefixes, longest first so "FS 595" wins over "FS".
    /// Each must be followed by something other than a letter or digit.
    private static let prefixes: [(pattern: String, system: PaintStandardSystem)] = [
        ("AMS-STD-595", .fs595), ("AMS STD 595", .fs595),
        ("FS 595", .fs595), ("FS-595", .fs595), ("FS595", .fs595),
        ("BS 381C", .bs381c), ("BS-381C", .bs381c), ("BS381C", .bs381c),
        ("BS 381", .bs381c), ("BS381", .bs381c), ("BSC", .bs381c),
        ("FS", .fs595), ("RAL", .ral), ("RLM", .rlm), ("BS", .bs381c),
        ("ANA", .ana), ("MAP", .map),
    ]

    /// Nil for empty text.
    static func parse(_ text: String) -> PaintStandard? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isSeveral(text) { return PaintStandard(system: .multiple, code: text) }
        // IJN and IJA keep their prefix in the code, as it says which service.
        for prefix in ["IJN", "IJA"] where hasPrefix(text, prefix) {
            return PaintStandard(system: .ijn, code: text)
        }
        for (prefix, system) in prefixes where hasPrefix(text, prefix) {
            let rest = text.dropFirst(prefix.count).drop { $0.isWhitespace || "-:#.".contains($0) }
            return PaintStandard(system: system, code: String(rest))
        }
        return PaintStandard(system: .custom, code: text)
    }

    /// "FS 36375 / BS 637", "RLM 74, RLM 75" or "FS 34102 & RAL 6003".
    private static func isSeveral(_ text: String) -> Bool {
        text.contains { "/,;&+".contains($0) }
    }

    /// Case-insensitive. A letter can't follow the prefix, so "Maple" isn't
    /// MAP, but a digit can: "FS36270". After a prefix ending in a digit or
    /// "C", such as "FS595" or "BS381C", neither can.
    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        guard text.count >= prefix.count,
              text.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
        else { return false }
        guard let next = text.dropFirst(prefix.count).first else { return true }
        let endsInNumber = prefix.last?.isNumber == true || prefix.hasSuffix("381C")
        return !next.isLetter && !(endsInNumber && next.isNumber)
    }
}

/// How closely a paint matches its standard. Only set when it has one.
nonisolated enum PaintMatch: String, CaseIterable, Identifiable, Sendable {
    /// Stored as "none".
    case noMatch = "none"
    case closest
    case exact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .noMatch: String(localized: "No Match")
        case .closest: String(localized: "Closest Match")
        case .exact: String(localized: "Exact Match")
        }
    }

    /// For the CSV: accepts the display names and raw values, ignoring case.
    init?(text: String) {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        let found = Self.allCases.first {
            [$0.rawValue, $0.displayName.lowercased(), $0.englishName.lowercased()].contains(key)
        }
        guard let found else { return nil }
        self = found
    }

    /// Written to the CSV, whatever the Mac's language.
    var englishName: String {
        switch self {
        case .noMatch: "No match"
        case .closest: "Closest match"
        case .exact: "Exact match"
        }
    }
}

/// What a paint is made with, so thinners and mixes aren't mixed up.
/// Set by the user; BenchBook never guesses it from the brand.
nonisolated enum PaintType: String, CaseIterable, Identifiable, Sendable {
    case waterAcrylic
    case alcoholAcrylic
    case lacquer
    case enamel
    case oil
    case polyurethane
    case acrylicWash
    case enamelWash
    case pigment
    case marker
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waterAcrylic: String(localized: "Water-Based Acrylic")
        case .alcoholAcrylic: String(localized: "Alcohol-Compatible Acrylic")
        case .lacquer: String(localized: "Lacquer")
        case .enamel: String(localized: "Enamel")
        case .oil: String(localized: "Oil Paint")
        case .polyurethane: String(localized: "Polyurethane-Based Paint")
        case .acrylicWash: String(localized: "Acrylic Wash")
        case .enamelWash: String(localized: "Enamel Wash")
        case .pigment: String(localized: "Pigment")
        case .marker: String(localized: "Marker")
        case .other: String(localized: "Other")
        }
    }

    /// The menu item's hint: what it's like, and examples.
    var hint: String {
        switch self {
        case .waterAcrylic:
            String(localized: "Low odour, fast drying, easy to brush, water cleanup. E.g. Vallejo Model Color, AK 3rd Gen, Ammo MIG, Citadel, Mr. Hobby Acrysion.")
        case .alcoholAcrylic:
            String(localized: "Fast drying, excellent for airbrushing, thinned with specialist thinners. E.g. Tamiya X/XF, Mr. Hobby Aqueous.")
        case .lacquer:
            String(localized: "Solvent-based, excellent adhesion, fast drying, hard finish, good for airbrushing. E.g. Mr. Color, Tamiya LP, MRP, AK Real Colors.")
        case .enamel:
            String(localized: "Solvent-based, slower drying, good levelling and brush painting. E.g. Humbrol Enamel, Tamiya Enamel, Revell Email Color.")
        case .oil:
            String(localized: "Very slow drying, excellent blending, mostly for weathering. E.g. Abteilung 502, Winsor & Newton.")
        case .polyurethane:
            String(localized: "Durable primers and coatings; depends on the formulation. E.g. Vallejo Surface Primer.")
        case .acrylicWash:
            String(localized: "Thin, water-based, for panel lines and shading; water cleanup. E.g. Vallejo Model Wash, Citadel Shade, AK Acrylic Wash.")
        case .enamelWash:
            String(localized: "Thin, solvent-based, for panel lines and filters; the excess is wiped off with enamel thinner. E.g. Ammo MIG Panel Line Wash, AK Interactive washes, Tamiya Panel Line Accent Color.")
        case .pigment:
            String(localized: "Dry powders for dust, mud and rust, set with a fixer or thinner. E.g. MIG Productions, AK Interactive Pigments, Vallejo Pigments.")
        case .marker:
            String(localized: "Paint or ink in a pen, for small details and touch-ups. E.g. Gundam Marker, Molotow Liquid Chrome, Tamiya Paint Marker.")
        case .other:
            String(localized: "Anything else, such as inks and metal waxes.")
        }
    }

    /// Written to the CSV, whatever the Mac's language.
    var englishName: String {
        switch self {
        case .waterAcrylic: "Water-based acrylic"
        case .alcoholAcrylic: "Alcohol-compatible acrylic"
        case .lacquer: "Lacquer"
        case .enamel: "Enamel"
        case .oil: "Oil paint"
        case .polyurethane: "Polyurethane-based paint"
        case .acrylicWash: "Acrylic wash"
        case .enamelWash: "Enamel wash"
        case .pigment: "Pigment"
        case .marker: "Marker"
        case .other: "Other"
        }
    }

    /// For the CSV: accepts the display names and raw values, ignoring case.
    init?(text: String) {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        let found = Self.allCases.first {
            [$0.rawValue.lowercased(), $0.displayName.lowercased(), $0.englishName.lowercased()].contains(key)
        }
        guard let found else { return nil }
        self = found
    }
}

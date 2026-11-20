import AppKit
import SwiftUI

/// How paints are identified for duplicate checks: brand, range and code,
/// ignoring case, spacing and code punctuation ("XF-54" = "xf 54" = "XF54").
nonisolated enum PaintIdentity {
    static func key(brand: String, range: String, code: String) -> String {
        [words(brand), words(range), compactCode(code)].joined(separator: "|")
    }

    /// A mix is known by brand and name, as its code is optional:
    /// "Custom", "Faded Sky Grey" gives "mix|custom|faded sky grey".
    static func mixKey(brand: String, name: String) -> String {
        ["mix", words(brand), words(name)].joined(separator: "|")
    }

    /// Folds case and spacing: " Tamiya  Acrylic" → "tamiya acrylic".
    static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func compactCode(_ code: String) -> String {
        code.lowercased().filter { !$0.isWhitespace && !"-_./".contains($0) }
    }

    /// Whether a paint matches a search, by brand, range, code, name or
    /// colour standard. Standards ignore spacing and punctuation, so
    /// "FS 36270" finds a paint noted as "FS36270" or "FS-36270 / BS 637".
    static func matches(_ query: String, brand: String, range: String, code: String, name: String,
                        standard: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if [brand, range, code, name, standard].contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return true
        }
        let folded = lettersAndDigits(query)
        return !folded.isEmpty && lettersAndDigits(standard).contains(folded)
    }

    private static func lettersAndDigits(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// A brand or range to filter the catalogue by, with how many paints have it.
nonisolated struct PaintFilterOption: Identifiable, Hashable {
    /// Folded with `PaintIdentity.words`, so "Tamiya" and "tamiya " match.
    let key: String
    /// The spelling most paints use.
    let name: String
    let count: Int

    var id: String { key }

    /// One option per distinct value, ignoring blanks, sorted by name.
    static func options(for values: [String]) -> [PaintFilterOption] {
        var spellings: [String: [String: Int]] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = PaintIdentity.words(trimmed)
            guard !key.isEmpty else { continue }
            spellings[key, default: [:]][trimmed, default: 0] += 1
        }
        return spellings.map { key, counts in
            let name = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!.key
            return PaintFilterOption(key: key, name: name, count: counts.values.reduce(0, +))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Which paints the catalogue and the paint picker show.
nonisolated struct PaintFilter: Equatable {
    /// One type, or paints with no type set.
    enum TypeChoice: Hashable {
        case type(PaintType)
        case notSet
    }

    /// A `PaintFilterOption.key`; nil shows every brand.
    var brand: String?
    /// A `PaintFilterOption.key`; nil shows every range.
    var range: String?
    /// Nil shows every type.
    var type: TypeChoice?
    var ownedOnly = false

    var isActive: Bool { brand != nil || range != nil || type != nil || ownedOnly }

    func includes(brand paintBrand: String, range paintRange: String, type paintType: PaintType? = nil,
                  isOwned: Bool) -> Bool {
        (brand == nil || PaintIdentity.words(paintBrand) == brand)
            && (range == nil || PaintIdentity.words(paintRange) == range)
            && (type == nil || type == (paintType.map(TypeChoice.type) ?? .notSet))
            && (!ownedOnly || isOwned)
    }
}

/// "#RRGGBB" ↔ colour, in sRGB.
nonisolated enum SwatchColor {
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Accepts "#RRGGBB", "RRGGBB" or "#RGB"; nil otherwise.
    static func components(of hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Normalizes user or CSV input to "#RRGGBB", or nil if it isn't a colour.
    static func normalized(_ text: String) -> String? {
        components(of: text).map { hex(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    static func color(_ hex: String?) -> Color? {
        guard let hex, let c = components(of: hex) else { return nil }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    static func hex(from color: Color) -> String? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return hex(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}

extension Paint {
    /// A mix is owned when its recipe has paints and you own every one.
    var isOwned: Bool {
        guard isMix else { return ownership != nil }
        let paints = recipePaints
        return !paints.isEmpty && paints.allSatisfy { $0.ownership != nil }
    }

    /// A mix's recipe, in order.
    var sortedRecipe: [PaintMixPart] {
        recipe.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    /// The paints in a mix's recipe, in order.
    var recipePaints: [Paint] { sortedRecipe.compactMap(\.paint) }

    /// A mix's recipe paints you don't own yet.
    var missingRecipePaints: [Paint] { recipePaints.filter { $0.ownership == nil } }

    /// e.g. "3 parts XF-2, 1 part XF-19". Empty for a paint that isn't a mix.
    var recipeSummary: String {
        sortedRecipe.compactMap { part in
            part.paint.map { MixAmount.line(parts: part.parts, paint: $0.shortName) }
        }
        .joined(separator: ", ")
    }

    /// The code, or the name when there's no code: "XF-2".
    var shortName: String { code.trimmedOrNil ?? name.trimmedOrNil ?? brand }

    /// What you'd buy to paint with this: itself, or a mix's recipe paints.
    var shoppingPaints: [Paint] { isMix ? recipePaints : [self] }

    /// Mixes whose recipe uses this paint, by name.
    var mixesUsingPaint: [Paint] {
        mixParts.compactMap(\.mix)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// e.g. "Tamiya XF-54 Dark Sea Grey".
    var displayName: String {
        [brand, code, name].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Nil when no standard system is set.
    var standard: PaintStandard? {
        PaintStandard(systemRaw: standardSystemRaw, code: standardCode)
    }

    /// e.g. "FS 36270", or empty.
    var standardText: String { standard?.displayText ?? "" }

    /// Only set when the paint has a standard.
    var match: PaintMatch? { standard == nil ? nil : PaintMatch(rawValue: matchRaw) }

    var type: PaintType? { PaintType(rawValue: typeRaw) }

    /// Range and colour standard, e.g. "Acrylic XF · FS 36270". A mix shows
    /// its recipe instead of a range: "Mix: 3 parts XF-2, 1 part XF-19".
    var secondaryLine: String {
        let first = isMix ? MixAmount.recipeLine(recipeSummary) : range
        return [first, standardText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// For sorting the Match column: exact first, then closest, no match, not set.
    var matchSortKey: Int {
        switch match {
        case .exact: 0
        case .closest: 1
        case .noMatch: 2
        case nil: 3
        }
    }

    /// For sorting the Type column: in menu order, with Not Set last.
    var typeSortKey: Int {
        type.flatMap { PaintType.allCases.firstIndex(of: $0) } ?? PaintType.allCases.count
    }

    /// Uses of this paint in projects that aren't Completed.
    var unfinishedProjectSelections: [ProjectPaint] {
        projectSelections.filter { $0.project.map { $0.status != .completed } ?? false }
    }

    /// Where a project that isn't Completed needs this paint: chosen for a
    /// colour itself, or in the recipe of a mix that's chosen (`mix` set).
    var unfinishedUses: [(selection: ProjectPaint, mix: Paint?)] {
        unfinishedProjectSelections.map { ($0, nil) }
            + mixesUsingPaint.flatMap { mix in mix.unfinishedProjectSelections.map { ($0, mix) } }
    }

    /// Not owned, and needed by a project that isn't Completed, itself or in
    /// a mix. A mix is never bought; its recipe paints are.
    var isToBuy: Bool { !isMix && !isOwned && !unfinishedUses.isEmpty }

    func matches(_ query: String) -> Bool {
        PaintIdentity.matches(query, brand: brand, range: range, code: code, name: name, standard: searchableStandard)
    }

    /// The standard as shown, plus its system's name, so "FS 595" and
    /// "BS 381C" find their paints too.
    var searchableStandard: String {
        guard let standard else { return "" }
        return [standard.displayText, standard.system.displayName].joined(separator: " ")
    }

    /// Names of the mixes using this paint, sorted.
    var mixNames: [String] { mixesUsingPaint.map(\.displayName) }

    /// Names of Projects using this paint, sorted.
    var projectNames: [String] {
        projectSelections.compactMap { $0.project?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether the paint follows `standard`, whatever the spelling.
    func hasStandard(_ standard: PaintStandard) -> Bool {
        self.standard?.matchKey == standard.matchKey
    }

    /// A clear, such as X-22 Clear or X-27 Clear Red (`PaintClarity`).
    var isClear: Bool { PaintClarity.isClear(name: name) }
}

extension ProjectPaint {
    /// The colour from the painting guide. Nil when no system is set.
    var guideStandard: PaintStandard? {
        PaintStandard(systemRaw: standardSystemRaw, code: standard ?? "")
    }

    /// e.g. "FS 36270", or empty.
    var standardText: String { guideStandard?.displayText ?? "" }
}

/// How a recipe's parts are written.
nonisolated enum MixAmount {
    /// "3", "1.5" or "0.25".
    static func text(_ parts: Double) -> String {
        parts.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// "1 part XF-19" or "3 parts XF-2".
    static func line(parts: Double, paint: String) -> String {
        parts == 1
            ? String(localized: "1 part \(paint)")
            : String(localized: "\(text(parts)) parts \(paint)")
    }

    /// "Mix: 3 parts XF-2, 1 part XF-19", or "Mix" with no recipe yet.
    static func recipeLine(_ summary: String) -> String {
        summary.isEmpty ? String(localized: "Mix") : String(localized: "Mix: \(summary)")
    }
}

/// The Owned tick box's help for a mix, which can't be ticked.
enum MixOwnership {
    static func help(for mix: Paint) -> String {
        if mix.recipe.isEmpty { return String(localized: "Add a recipe to this mix. It's owned when you own every paint in it.") }
        let missing = mix.missingRecipePaints.map(\.displayName)
        if missing.isEmpty { return String(localized: "You own every paint in this mix") }
        return String(localized: "Not owned yet: \(missing.formatted(.list(type: .and)))")
    }
}

/// Which paints are clears, drawn as glass. Worked out from the name, so
/// nothing is stored.
nonisolated enum PaintClarity {
    /// True when the name has the word "clear" in it, ignoring case: "Clear",
    /// "Flat clear", "Clear Red", "Semi-Gloss Super Clear". "Unclear" isn't.
    static func isClear(name: String) -> Bool {
        name.split { !$0.isLetter }.contains { $0.compare("clear", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

/// A small round swatch, or an empty outline when no colour is set. Clears
/// are drawn as glass: their colour, see-through over a faint checkerboard,
/// with a highlight across the top. A clear without a colour is clear glass.
struct PaintSwatch: View {
    let hex: String?
    var isClear = false
    var size: CGFloat = 16

    var body: some View {
        Group {
            if isClear {
                glass(tint: SwatchColor.color(hex) ?? .white)
            } else if let color = SwatchColor.color(hex) {
                Circle().fill(color)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            } else {
                Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func glass(tint: Color) -> some View {
        ZStack {
            Checkerboard(squares: 4)
            Circle().fill(tint.opacity(0.55))
            // The highlight: a soft white band over the top half.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.7, height: size * 0.45)
                .offset(y: -size * 0.2)
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
    }
}

/// A faint checkerboard, like the one behind see-through images.
private struct Checkerboard: View {
    let squares: Int

    var body: some View {
        Canvas { context, size in
            let side = size.width / CGFloat(squares)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<squares {
                for column in 0..<squares where (row + column).isMultiple(of: 2) {
                    let square = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(square), with: .color(.gray.opacity(0.35)))
                }
            }
        }
    }
}

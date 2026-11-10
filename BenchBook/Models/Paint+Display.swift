import AppKit
import SwiftUI

/// How paints are identified for duplicate checks: brand, range and code,
/// ignoring case, spacing and code punctuation ("XF-54" = "xf 54" = "XF54").
nonisolated enum PaintIdentity {
    static func key(brand: String, range: String, code: String) -> String {
        [words(brand), words(range), compactCode(code)].joined(separator: "|")
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

/// Which paints the catalogue shows.
nonisolated struct PaintFilter: Equatable {
    /// A `PaintFilterOption.key`; nil shows every brand.
    var brand: String?
    /// A `PaintFilterOption.key`; nil shows every range.
    var range: String?
    var ownedOnly = false

    var isActive: Bool { brand != nil || range != nil || ownedOnly }

    func includes(brand paintBrand: String, range paintRange: String, isOwned: Bool) -> Bool {
        (brand == nil || PaintIdentity.words(paintBrand) == brand)
            && (range == nil || PaintIdentity.words(paintRange) == range)
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
    var isOwned: Bool { ownership != nil }

    /// e.g. "Tamiya XF-54 Dark Sea Grey".
    var displayName: String {
        [brand, code, name].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Range and colour standard, e.g. "Acrylic XF · FS 36270".
    var secondaryLine: String {
        [range, standardCode].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Uses of this paint in projects that aren't Completed.
    var unfinishedProjectSelections: [ProjectPaint] {
        projectSelections.filter { $0.project.map { $0.status != .completed } ?? false }
    }

    /// Not owned, and needed by a project that isn't Completed.
    var isToBuy: Bool { !isOwned && !unfinishedProjectSelections.isEmpty }

    func matches(_ query: String) -> Bool {
        PaintIdentity.matches(query, brand: brand, range: range, code: code, name: name, standard: standardCode)
    }

    /// Names of Projects using this paint, sorted.
    var projectNames: [String] {
        projectSelections.compactMap { $0.project?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// A small round swatch, or an empty outline when no colour is set.
struct PaintSwatch: View {
    let hex: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let color = SwatchColor.color(hex) {
                Circle().fill(color)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            } else {
                Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

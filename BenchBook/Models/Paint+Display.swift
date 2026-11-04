import AppKit
import SwiftUI

/// How paints are identified for duplicate checks: brand, range and code,
/// ignoring case, spacing and code punctuation ("XF-54" = "xf 54" = "XF54").
nonisolated enum PaintIdentity {
    static func key(brand: String, range: String, code: String) -> String {
        [words(brand), words(range), compactCode(code)].joined(separator: "|")
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func compactCode(_ code: String) -> String {
        code.lowercased().filter { !$0.isWhitespace && !"-_./".contains($0) }
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

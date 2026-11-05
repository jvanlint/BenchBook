import SwiftUI

/// Tags as capsules tinted with each tag's colour, wrapping onto new
/// lines. Long lists show the first few and a "+N" chip.
struct TagChips: View {
    struct Chip: Hashable {
        let name: String
        let color: Color
    }

    let chips: [Chip]
    var limit = 5

    init(tags: [Tag], limit: Int = 5) {
        chips = tags.map { Chip(name: $0.name, color: $0.displayColor) }
        self.limit = limit
    }

    init(chips: [Chip], limit: Int = 5) {
        self.chips = chips
        self.limit = limit
    }

    private var names: [String] { chips.map(\.name) }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(chips.prefix(limit), id: \.self) { chip in
                Self.chip(chip.name, color: chip.color)
            }
            if chips.count > limit {
                Self.chip("+\(chips.count - limit)", color: .secondary)
                    .help(names.dropFirst(limit).joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tags: \(names.joined(separator: ", "))"))
    }

    static func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .tagPillStyle(color: color)
    }
}

extension View {
    /// The look shared by every tag pill. See `TagPillStyle`.
    func tagPillStyle(color: Color, isPartial: Bool = false, isSelected: Bool = false) -> some View {
        modifier(TagPillStyle(color: color, isPartial: isPartial, isSelected: isSelected))
    }
}

/// A tag pill: tinted fill, a border in the tag's colour, and text that
/// stays readable for light colours such as yellow. In light mode the text
/// is darkened toward black; in dark mode it gets a faint shadow.
/// A partial pill (a tag on only some selected items) is paler and dashed;
/// a selected one (an active filter) is fuller with a thicker border.
struct TagPillStyle: ViewModifier {
    let color: Color
    var isPartial = false
    var isSelected = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        content
            .foregroundStyle(isDark
                ? color.mix(with: .white, by: isSelected ? 0.25 : 0.1)
                : color.mix(with: .black, by: isSelected ? 0.5 : 0.4))
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 0.5, x: 0, y: 0.5)
            .background(color.opacity(fillOpacity(isDark: isDark)), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    color.opacity(isDark ? 0.75 : 0.85),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isPartial ? [3, 2] : [])
                )
            )
    }

    private func fillOpacity(isDark: Bool) -> Double {
        if isPartial { return 0.05 }
        if isSelected { return isDark ? 0.4 : 0.35 }
        return isDark ? 0.15 : 0.18
    }
}

/// Places subviews left to right, wrapping to a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes(subviews[index], maxWidth: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A chip wider than the row is narrowed to fit; its text truncates.
    private func sizes(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = sizes(subviews[index], maxWidth: maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

#Preview {
    TagChips(chips: ["wheel well", "cockpit", "decals", "main gear", "FS 36270", "weathering", "ejection seat"]
        .map { TagChips.Chip(name: $0, color: .accentColor) })
        .frame(width: 220)
        .padding()
}

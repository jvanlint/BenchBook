import SwiftUI

/// Tags as tinted capsules that wrap onto new lines. Long lists show the
/// first few and a "+N" chip; the full list is in Edit Details.
struct TagChips: View {
    let names: [String]
    var limit = 5

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(names.prefix(limit), id: \.self) { name in
                chip(name)
            }
            if names.count > limit {
                chip("+\(names.count - limit)")
                    .help(names.dropFirst(limit).joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tags: \(names.joined(separator: ", "))"))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.15), in: Capsule())
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
    TagChips(names: ["wheel well", "cockpit", "decals", "main gear", "FS 36270", "weathering", "ejection seat"])
        .frame(width: 220)
        .padding()
}

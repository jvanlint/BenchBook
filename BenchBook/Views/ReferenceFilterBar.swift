import SwiftUI

/// Type menu and tag toggles shown above the References grid.
struct ReferenceFilterBar: View {
    @Binding var filter: ReferenceFilter
    /// Kinds present in the Project, with counts, in display order.
    /// Tags are listed most-used first, without counts.
    let kinds: [(kind: ReferenceKind, count: Int)]
    let tags: [TagUsage]
    let totalCount: Int
    let matchingCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Type", selection: $filter.kind) {
                Text("All Types (\(totalCount))").tag(ReferenceKind?.none)
                Divider()
                ForEach(kinds, id: \.kind) { entry in
                    Label("\(entry.kind.pluralName) (\(entry.count))", systemImage: entry.kind.systemImage)
                        .tag(Optional(entry.kind))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show only one type of reference")

            if !tags.isEmpty {
                Divider()
                    .frame(height: 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(tags) { tag in
                            filterPill(tag)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            } else {
                Spacer()
            }

            if filter.isActive {
                Text("\(matchingCount) of \(totalCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                Button("Clear") { filter = ReferenceFilter() }
                    .help("Show all references")
            }
        }
        // One size for every control, so the menu and tag buttons line up.
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    /// A tag pill that switches its filter on and off. On shows a checkmark,
    /// a fuller fill and a thicker border.
    private func filterPill(_ tag: TagUsage) -> some View {
        let isOn = filter.tags.contains(tag.normalizedName)
        let color = tag.colorName.flatMap(TagColor.init(rawValue:))?.color ?? .accentColor
        return Button {
            filter.toggle(tag: tag.normalizedName)
        } label: {
            HStack(spacing: 3) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(tag.name)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .tagPillStyle(color: color, isSelected: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Stop filtering by “\(tag.name)”" : "Show only references tagged “\(tag.name)”")
        .accessibilityLabel(tag.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension ReferenceKind {
    var pluralName: String {
        switch self {
        case .image: String(localized: "Images")
        case .pdf: String(localized: "PDFs")
        case .markdown: String(localized: "Markdown Files")
        case .webpage: String(localized: "Webpages")
        case .videoLink: String(localized: "Videos")
        case .textSnippet: String(localized: "Text Snippets")
        case .note: String(localized: "Notes")
        }
    }
}

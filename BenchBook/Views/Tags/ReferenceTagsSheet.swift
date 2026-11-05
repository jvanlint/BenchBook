import SwiftData
import SwiftUI

/// The References whose tags are being edited, for `.sheet(item:)`.
struct TagEditingTarget: Identifiable {
    let id = UUID()
    let references: [Reference]
}

/// Adds and removes tags on one or more References. Changes apply at once.
/// A tag on only some of them is shown dashed; clicking it adds it to all.
struct ReferenceTagsSheet: View {
    let references: [Reference]

    @Query(sort: [SortDescriptor(\Tag.name, comparator: .localizedStandard)])
    private var tags: [Tag]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var newTags = ""
    @State private var errorMessage: String?

    private var service: TagService { TagService(context: modelContext) }

    private var applied: [(tag: Tag, state: TagState)] {
        tags.map { ($0, service.state(of: $0, on: references)) }.filter { $0.state != .none }
    }

    /// Other tags to add with one click, most used first.
    private var suggestions: [Tag] {
        let appliedIDs = Set(applied.map(\.tag.id))
        return tags.filter { !appliedIDs.contains($0.id) }.sorted(by: Tag.byUsage).prefix(24).map { $0 }
    }

    private var title: String {
        references.count == 1
            ? String(localized: "Tags for “\(references[0].displayTitle)”")
            : String(localized: "Tags for \(references.count) References")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .lineLimit(2)

            if applied.isEmpty {
                Text("No tags yet.")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(applied, id: \.tag.id) { entry in
                        appliedChip(entry.tag, state: entry.state)
                    }
                }
            }

            TextField("Add Tags", text: $newTags, prompt: Text("Type tags, separated with commas, then press Return"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTyped)
                .textInputSuggestions {
                    ForEach(matchingNames, id: \.self) { name in
                        // Keep any tags typed before the last comma.
                        Text(name).textInputCompletion(typedPrefix + name)
                    }
                }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add an existing tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions) { tag in
                            Button {
                                perform { try service.add(tag, to: references) }
                            } label: {
                                TagChips.chip(tag.name, color: tag.displayColor)
                            }
                            .buttonStyle(.plain)
                            .help("Add “\(tag.name)”")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    addTyped()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .alert(
            "Couldn't Change Tags",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A tag on all References has a remove button; one on some is dashed
    /// and adds itself to the rest when clicked.
    @ViewBuilder
    private func appliedChip(_ tag: Tag, state: TagState) -> some View {
        let color = tag.displayColor
        HStack(spacing: 4) {
            if state == .some {
                Button {
                    perform { try service.add(tag, to: references) }
                } label: {
                    Text(tag.name)
                }
                .buttonStyle(.plain)
                .help("On some of these references. Click to add it to all of them.")
            } else {
                Text(tag.name)
            }
            Button {
                perform { try service.remove(tag, from: references) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(tag.name)")
            .help("Remove “\(tag.name)”")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .tagPillStyle(color: color, isPartial: state == .some)
    }

    /// Existing tag names matching the word being typed.
    private var matchingNames: [String] {
        guard let typed = newTags.split(separator: ",").last.map({ TagNames.normalize(String($0)) }), !typed.isEmpty else {
            return []
        }
        return tags.filter { $0.normalizedName.contains(typed) && $0.normalizedName != typed }.prefix(8).map(\.name)
    }

    /// Everything up to and including the last comma.
    private var typedPrefix: String {
        guard let comma = newTags.lastIndex(of: ",") else { return "" }
        return String(newTags[...comma]) + " "
    }

    private func addTyped() {
        guard !TagNames.parse(newTags).isEmpty else { return }
        perform { try service.addTags(named: newTags, to: references) }
        newTags = ""
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

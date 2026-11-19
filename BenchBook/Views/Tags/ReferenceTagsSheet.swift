import SwiftData
import SwiftUI

/// The References whose tags are being edited, for `.sheet(item:)`.
struct TagEditingTarget: Identifiable {
    let id = UUID()
    let references: [Reference]
}

/// What a tags sheet edits: References, or build photos.
enum TaggedItems {
    case references([Reference])
    case photos([BuildPhoto])
}

/// Adds and removes tags on one or more References or build photos.
/// Changes apply at once. A tag on only some of them is shown dashed;
/// clicking it adds it to all.
struct ReferenceTagsSheet: View {
    let items: TaggedItems

    init(references: [Reference]) {
        items = .references(references)
    }

    init(photos: [BuildPhoto]) {
        items = .photos(photos)
    }

    @Query(sort: [SortDescriptor(\Tag.name, comparator: .localizedStandard)])
    private var tags: [Tag]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var newTags = ""
    @State private var errorMessage: String?

    private var service: TagService { TagService(context: modelContext) }

    private var applied: [(tag: Tag, state: TagState)] {
        tags.map { ($0, state(of: $0)) }.filter { $0.state != .none }
    }

    /// Other tags to add with one click, most used first.
    private var suggestions: [Tag] {
        let appliedIDs = Set(applied.map(\.tag.id))
        return tags.filter { !appliedIDs.contains($0.id) }.sorted(by: Tag.byUsage).prefix(24).map { $0 }
    }

    private var title: String {
        switch items {
        case .references(let references):
            references.count == 1
                ? String(localized: "Tags for “\(references[0].displayTitle)”")
                : String(localized: "Tags for \(references.count) References")
        case .photos(let photos):
            photos.count == 1
                ? String(localized: "Tags for “\(photos[0].displayTitle)”")
                : String(localized: "Tags for \(photos.count) Build Photos")
        }
    }

    // MARK: Applying to the items

    private func state(of tag: Tag) -> TagState {
        switch items {
        case .references(let references): service.state(of: tag, on: references)
        case .photos(let photos): service.state(of: tag, on: photos)
        }
    }

    private func add(_ tag: Tag) throws {
        switch items {
        case .references(let references): try service.add(tag, to: references)
        case .photos(let photos): try service.add(tag, to: photos)
        }
    }

    private func remove(_ tag: Tag) throws {
        switch items {
        case .references(let references): try service.remove(tag, from: references)
        case .photos(let photos): try service.remove(tag, from: photos)
        }
    }

    private func addTags(named text: String) throws {
        switch items {
        case .references(let references): try service.addTags(named: text, to: references)
        case .photos(let photos): try service.addTags(named: text, to: photos)
        }
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
                                perform { try add(tag) }
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
                    perform { try add(tag) }
                } label: {
                    Text(tag.name)
                }
                .buttonStyle(.plain)
                .help("On some of these. Click to add it to all of them.")
            } else {
                Text(tag.name)
            }
            Button {
                perform { try remove(tag) }
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
        perform { try addTags(named: newTags) }
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

import SwiftData
import SwiftUI

/// Creates a tag, or renames one. Renaming to another tag's name offers
/// to merge the two.
struct TagNameSheet: View {
    enum Mode: Identifiable {
        case new
        case rename(Tag)

        var id: String {
            switch self {
            case .new: "new"
            case .rename(let tag): tag.id.uuidString
            }
        }
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var mergeTarget: Tag?
    @State private var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        if case .rename(let tag) = mode {
            _name = State(initialValue: tag.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var service: TagService { TagService(context: modelContext) }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("e.g. Cockpit"))
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .navigationTitle(isNew ? "New Tag" : "Rename Tag")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Rename", action: save)
                    .disabled(TagNames.parse(name).isEmpty)
            }
        }
        .confirmationDialog(
            "“\(mergeTarget?.name ?? "")” Already Exists",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            presenting: mergeTarget
        ) { _ in
            Button("Merge Tags") { rename(merging: true) }
        } message: { target in
            Text("Merge the two tags? References tagged with either will have “\(target.name)”.")
        }
        .alert(
            "Couldn't Save Tag",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isNew: Bool {
        if case .new = mode { true } else { false }
    }

    private func save() {
        do {
            switch mode {
            case .new:
                if try service.existingTag(named: name) == nil {
                    try service.createTag(named: name)
                }
                dismiss()
            case .rename(let tag):
                if let existing = try service.existingTag(named: name), existing.id != tag.id {
                    mergeTarget = existing
                } else {
                    rename(merging: false)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(merging: Bool) {
        guard case .rename(let tag) = mode else { return }
        do {
            try service.rename(tag, to: name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Picks a tag colour, shown as coloured dots in menus.
struct TagColorPicker: View {
    let tags: [Tag]

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Picker("Colour", selection: Binding(
            get: { tags.count == 1 ? tags[0].tagColor : nil },
            set: { color in try? TagService(context: modelContext).setColor(color, for: tags) }
        )) {
            ForEach(TagColor.allCases) { color in
                Image(systemName: "circle.fill")
                    .tint(color.color)
                    .accessibilityLabel(color.displayName)
                    .tag(Optional(color))
            }
            Image(systemName: "circle.slash")
                .accessibilityLabel("No Colour")
                .tag(TagColor?.none)
        }
        .pickerStyle(.palette)
    }
}

/// A tag's colour dot. Clicking it opens a palette of colours.
///
/// Drawn as a plain view rather than a menu's label: macOS turns menu
/// labels into fixed images, so a colour change wouldn't show.
struct TagColorButton: View {
    let tag: Tag

    @Environment(\.modelContext) private var modelContext
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            Circle()
                .fill(tag.displayColor)
                .frame(width: 12, height: 12)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change the colour of “\(tag.name)”")
        .accessibilityLabel("Colour: \(tag.tagColor?.displayName ?? String(localized: "Default"))")
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            palette
        }
    }

    private var palette: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 7), spacing: 8) {
            ForEach(TagColor.allCases) { color in
                swatch(color.color, isSelected: tag.tagColor == color, label: color.displayName) {
                    choose(color)
                }
            }
            swatch(.accentColor, isSelected: tag.tagColor == nil, label: String(localized: "Default")) {
                choose(nil)
            }
            .overlay {
                Image(systemName: "slash.circle")
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
        }
        .padding(12)
    }

    private func swatch(_ color: Color, isSelected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(.primary, lineWidth: 2).padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ color: TagColor?) {
        try? TagService(context: modelContext).setColor(color, for: [tag])
        isPicking = false
    }
}


import SwiftData
import SwiftUI

/// A Project's Paint section: the colours this build needs and the paint
/// chosen for each.
struct ProjectPaintView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @State private var selection = Set<UUID>()
    @State private var isPicking = false
    @State private var isAddingColour = false
    /// The colour row a paint is being chosen for.
    @State private var choosingFor: ProjectPaint?
    @State private var errorMessage: String?

    private var service: PaintService { PaintService(context: modelContext) }
    private var rows: [ProjectPaint] { project.sortedPaintRequirements }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Paint", systemImage: "paintpalette")
                } description: {
                    Text("Add the colours from the painting guide, such as FS 36270, then choose a paint for each. Or add paints from your catalogue directly.")
                } actions: {
                    Button("Add Colour…") { isAddingColour = true }
                    Button("Add Paint…") { isPicking = true }
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    table
                }
            }
        }
        .sheet(isPresented: $isPicking) {
            PaintPickerView(project: project)
        }
        .sheet(item: $choosingFor) { row in
            PaintPickerView(project: project, row: row)
        }
        .sheet(isPresented: $isAddingColour) {
            AddColourSheet(project: project)
        }
        .onDisappear { try? service.commit() }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            let paints = rows.filter { $0.selectedPaint != nil }.count
            let toBuy = rows.filter { $0.selectedPaint?.isOwned == false }.count
            let unchosen = rows.count - paints
            Text("^[\(paints) paint](inflect: true)")
            if toBuy > 0 {
                Text("·")
                    .foregroundStyle(.secondary)
                Label("\(toBuy) to buy", systemImage: "cart")
                    .foregroundStyle(.orange)
            }
            if unchosen > 0 {
                Text("·")
                    .foregroundStyle(.secondary)
                Label("^[\(unchosen) colour](inflect: true) without paint", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Colour…", systemImage: "plus") { isAddingColour = true }
                .help("Add a colour from the painting guide, such as FS 36270")
            Button("Add Paint…", systemImage: "plus") { isPicking = true }
                .help("Add paints from your catalogue")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Swatch") { row in
                PaintSwatch(hex: row.selectedPaint?.swatchHex)
            }
            .width(48)
            TableColumn("Paint") { row in
                if let paint = row.selectedPaint {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paint.displayName)
                        if !paint.secondaryLine.isEmpty {
                            Text(paint.secondaryLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button("Choose Paint…") { choosingFor = row }
                        .help("Choose a paint from your catalogue for this colour")
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Colour") { row in
                TextField(
                    "Colour",
                    text: Binding(get: { row.standard ?? "" }, set: { service.setStandard($0, on: row) }),
                    prompt: Text("e.g. FS 36270")
                )
                .textFieldStyle(.plain)
                .onSubmit { commit() }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Used For") { row in
                TextField(
                    "Used For",
                    text: Binding(get: { row.usedFor ?? "" }, set: { service.setUsedFor($0, on: row) }),
                    prompt: Text("e.g. upper surfaces")
                )
                .textFieldStyle(.plain)
                .onSubmit { commit() }
            }
            .width(min: 140, ideal: 260)
            TableColumn("Owned") { row in
                if let paint = row.selectedPaint {
                    Toggle("Owned", isOn: Binding(
                        get: { paint.isOwned },
                        set: { owned in perform { try service.setOwned(owned, for: paint) } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Owned: \(paint.displayName)")
                    .help(paint.isOwned ? "You own this paint" : "You don't own this paint yet")
                }
            }
            .width(50)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if chosen.count == 1, let row = chosen.first {
                Button(row.selectedPaint == nil ? "Choose Paint…" : "Change Paint…") { choosingFor = row }
                Divider()
            }
            if !chosen.isEmpty {
                Button(chosen.count == 1 ? "Remove from Project" : "Remove \(chosen.count) Rows from Project") {
                    remove(chosen)
                }
            }
        } primaryAction: { ids in
            // Double-clicking a colour with no paint chooses one.
            if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }), row.selectedPaint == nil {
                choosingFor = row
            }
        }
        .onDeleteCommand {
            remove(rows.filter { selection.contains($0.id) })
        }
        .onChange(of: selection) { commit() }
    }

    /// Removing only takes the paint off this project; the catalogue keeps it.
    private func remove(_ chosen: [ProjectPaint]) {
        perform {
            for row in chosen { try service.remove(row) }
        }
        selection.subtract(chosen.map(\.id))
    }

    private func commit() {
        perform { try service.commit() }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet for adding a colour from the painting guide, before choosing a paint.
private struct AddColourSheet: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var standard = ""
    @State private var usedFor = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Colour", text: $standard, prompt: Text("e.g. FS 36270 or RLM 74"))
                TextField("Used For", text: $usedFor, prompt: Text("e.g. upper surfaces"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Colour", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(standard.trimmedOrNil == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 380)
        .navigationTitle("Add Colour")
        .alert(
            "Couldn't Add Colour",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add() {
        do {
            try PaintService(context: modelContext).addColour(standard: standard, usedFor: usedFor, to: project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

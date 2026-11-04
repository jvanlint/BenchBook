import SwiftData
import SwiftUI

/// A Project's Paint section: the paints chosen for this build.
struct ProjectPaintView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @State private var selection = Set<UUID>()
    @State private var isPicking = false
    @State private var errorMessage: String?

    private var service: PaintService { PaintService(context: modelContext) }
    private var rows: [ProjectPaint] { project.sortedPaintRequirements }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Paint", systemImage: "paintpalette")
                } description: {
                    Text("Add the paints this build needs from your paint catalogue.")
                } actions: {
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
            let toBuy = rows.filter { $0.selectedPaint?.isOwned == false }.count
            Text("\(rows.count) paints")
            if toBuy > 0 {
                Text("·")
                    .foregroundStyle(.secondary)
                Label("\(toBuy) to buy", systemImage: "cart")
                    .foregroundStyle(.orange)
            }
            Spacer()
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.selectedPaint?.displayName ?? String(localized: "Missing Paint"))
                    if let line = row.selectedPaint?.secondaryLine, !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 240)
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
            if !chosen.isEmpty {
                Button(chosen.count == 1 ? "Remove from Project" : "Remove \(chosen.count) Paints from Project") {
                    remove(chosen)
                }
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

import SwiftData
import SwiftUI

/// Sheet for choosing catalogue paints to add to a Project, or the paint
/// for one of its colours. New paints can be created here without leaving
/// the project.
struct PaintPickerView: View {
    let project: Project
    /// The colour row to choose a paint for. Nil adds paints as new rows.
    var row: ProjectPaint?

    @Query(sort: [
        SortDescriptor(\Paint.brand, comparator: .localizedStandard),
        SortDescriptor(\Paint.code, comparator: .localizedStandard),
    ])
    private var paints: [Paint]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var chosen = Set<UUID>()
    @State private var searchText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Paints not already in the project, matching the search. When
    /// choosing for a colour, paints you own come first.
    private var candidates: [Paint] {
        let inProject = Set(project.paintRequirements.compactMap { $0.selectedPaint?.id })
        let matching = paints.filter { !inProject.contains($0.id) && $0.matches(searchText) }
        guard row != nil else { return matching }
        return matching.filter(\.isOwned) + matching.filter { !$0.isOwned }
    }

    private var title: String {
        guard let row else { return String(localized: "Add Paint to \(project.name)") }
        if let standard = row.standard {
            return String(localized: "Choose Paint for \(standard)")
        }
        return String(localized: "Choose Paint")
    }

    private var addTitle: String {
        if row != nil { return String(localized: "Choose Paint") }
        return chosen.count > 1 ? String(localized: "Add \(chosen.count) Paints") : String(localized: "Add Paint")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
            TextField("Search", text: $searchText, prompt: Text("Search brand, code, name or FS/RLM"))
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if candidates.isEmpty {
                ContentUnavailableView {
                    Label(paints.isEmpty ? "No Paints in Catalogue" : "No Paints to Add", systemImage: "paintpalette")
                } description: {
                    Text(paints.isEmpty
                         ? "Create a paint here, or add many at once from Paints in the sidebar."
                         : searchText.isEmpty
                         ? "Every paint is already in this project."
                         : "No paint in your catalogue matches “\(searchText)”, or every match is already in this project.")
                } actions: {
                    Button("New Paint…") { isCreating = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(candidates) { paint in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(paint.id) },
                        set: { toggle(paint.id, on: $0) }
                    )) {
                        HStack(spacing: 8) {
                            PaintSwatch(hex: paint.swatchHex)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(paint.displayName)
                                if !paint.secondaryLine.isEmpty {
                                    Text(paint.secondaryLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if paint.isOwned {
                                Text("Owned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()
            HStack {
                Button("New Paint…") { isCreating = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle, action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .sheet(isPresented: $isCreating) {
            PaintEditorView(request: .new, standardCode: row?.standard ?? "") { paint in toggle(paint.id, on: true) }
        }
        .onAppear {
            if let standard = row?.standard { searchText = standard }
        }
        .alert(
            "Couldn't Add Paint",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Choosing for a colour picks one paint; adding picks any number.
    private func toggle(_ id: UUID, on: Bool) {
        if !on {
            chosen.remove(id)
        } else if row != nil {
            chosen = [id]
        } else {
            chosen.insert(id)
        }
    }

    private func add() {
        let service = PaintService(context: modelContext)
        do {
            if let row {
                guard let paint = paints.first(where: { chosen.contains($0.id) }) else { return }
                try service.choose(paint, for: row)
            } else {
                try service.add(paints.filter { chosen.contains($0.id) }, to: project)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

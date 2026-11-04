import SwiftData
import SwiftUI

/// Sheet for choosing catalogue paints to add to a Project. New paints can
/// be created here without leaving the project.
struct PaintPickerView: View {
    let project: Project

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

    /// Paints not already in the project, matching the search.
    private var candidates: [Paint] {
        let inProject = Set(project.paintRequirements.compactMap { $0.selectedPaint?.id })
        return paints
            .filter { !inProject.contains($0.id) }
            .filter { paint in
                searchText.isEmpty || [paint.brand, paint.range, paint.code, paint.name, paint.standardCode]
                    .contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Paint to \(project.name)")
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
                         : "Every matching paint is already in this project.")
                } actions: {
                    Button("New Paint…") { isCreating = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(candidates) { paint in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(paint.id) },
                        set: { if $0 { chosen.insert(paint.id) } else { chosen.remove(paint.id) } }
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
                Button(chosen.count > 1 ? "Add \(chosen.count) Paints" : "Add Paint", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .sheet(isPresented: $isCreating) {
            PaintEditorView(request: .new) { paint in chosen.insert(paint.id) }
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

    private func add() {
        do {
            try PaintService(context: modelContext).add(paints.filter { chosen.contains($0.id) }, to: project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

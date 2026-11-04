import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The library-wide paint catalogue: a sortable, searchable table.
struct PaintCatalogueView: View {
    @Query private var paints: [Paint]
    @Environment(\.modelContext) private var modelContext

    @State private var selection = Set<UUID>()
    @State private var sortOrder = [
        KeyPathComparator(\Paint.brand, comparator: .localizedStandard),
        KeyPathComparator(\Paint.code, comparator: .localizedStandard),
    ]
    @State private var searchText = ""
    @State private var showsOwnedOnly = false
    @State private var editorRequest: PaintEditorRequest?
    @State private var isImporting = false
    @State private var pendingDeletion: [Paint] = []
    @State private var alert: (title: String, message: String)?

    private var service: PaintService { PaintService(context: modelContext) }

    private var visiblePaints: [Paint] {
        paints
            .filter { !showsOwnedOnly || $0.isOwned }
            .filter { paint in
                searchText.isEmpty || [paint.brand, paint.range, paint.code, paint.name, paint.standardCode, paint.notes ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted(using: sortOrder)
    }

    private var selectedPaints: [Paint] {
        paints.filter { selection.contains($0.id) }
    }

    var body: some View {
        content
            .navigationTitle("Paints")
            .navigationSubtitle(subtitle)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search Paints")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $showsOwnedOnly) {
                        Label("Owned Only", systemImage: "checkmark.circle")
                    }
                    .help("Show only paints you own")

                    Button("Import CSV…", systemImage: "square.and.arrow.down") { isImporting = true }
                        .help("Import paints from a CSV file")

                    Button("Add Paint", systemImage: "plus") { editorRequest = .new }
                        .help("Add a paint to the catalogue")
                }
            }
            .sheet(item: $editorRequest) { request in
                PaintEditorView(request: request) { paint in selection = [paint.id] }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                if case .success(let url) = result { importCSV(from: url) }
            }
            .confirmationDialog(
                pendingDeletion.count == 1
                    ? "Delete “\(pendingDeletion.first?.displayName ?? "")”?"
                    : "Delete \(pendingDeletion.count) Paints?",
                isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
            ) {
                Button("Delete", role: .destructive) { delete(pendingDeletion) }
            } message: {
                Text("Paints used in a project can't be deleted until they're removed from it.")
            }
            .alert(
                alert?.title ?? "",
                isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alert?.message ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if paints.isEmpty {
            ContentUnavailableView {
                Label("No Paints", systemImage: "paintpalette")
            } description: {
                Text("Add the paints you use, or import a CSV file with Brand, Range, Code, Name, FS/RLM, Colour and Owned columns.")
            } actions: {
                Button("Add Paint") { editorRequest = .new }
                    .buttonStyle(.borderedProminent)
                Button("Import CSV…") { isImporting = true }
            }
        } else if visiblePaints.isEmpty {
            ContentUnavailableView {
                Label("No Matching Paints", systemImage: "magnifyingglass")
            } description: {
                Text(showsOwnedOnly ? "No paints you own match your search." : "No paints match your search.")
            } actions: {
                Button("Show All Paints") {
                    searchText = ""
                    showsOwnedOnly = false
                }
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(visiblePaints, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Swatch") { paint in
                PaintSwatch(hex: paint.swatchHex)
            }
            .width(48)
            TableColumn("Brand", value: \.brand, comparator: .localizedStandard)
            TableColumn("Range", value: \.range, comparator: .localizedStandard)
            TableColumn("Code", value: \.code, comparator: .localizedStandard)
                .width(min: 60, ideal: 80)
            TableColumn("Name", value: \.name, comparator: .localizedStandard)
                .width(min: 120, ideal: 200)
            TableColumn("FS / RLM", value: \.standardCode, comparator: .localizedStandard)
                .width(min: 70, ideal: 100)
            TableColumn("Owned") { paint in
                Toggle("Owned", isOn: Binding(
                    get: { paint.isOwned },
                    set: { owned in perform { try service.setOwned(owned, for: paint) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Owned: \(paint.displayName)")
            }
            .width(50)
            TableColumn("Projects") { paint in
                Text(paint.projectNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let chosen = paints.filter { ids.contains($0.id) }
            if chosen.count == 1, let paint = chosen.first {
                Button("Edit Paint…") { editorRequest = .edit(paint) }
            }
            if !chosen.isEmpty {
                if chosen.contains(where: { !$0.isOwned }) {
                    Button("Mark as Owned") { setOwned(true, chosen) }
                }
                if chosen.contains(where: \.isOwned) {
                    Button("Mark as Not Owned") { setOwned(false, chosen) }
                }
                Divider()
                Button(chosen.count == 1 ? "Delete Paint…" : "Delete \(chosen.count) Paints…", role: .destructive) {
                    pendingDeletion = chosen
                }
            }
        } primaryAction: { ids in
            if let paint = paints.first(where: { ids.contains($0.id) }) {
                editorRequest = .edit(paint)
            }
        }
        .onDeleteCommand {
            if !selectedPaints.isEmpty { pendingDeletion = selectedPaints }
        }
    }

    private var subtitle: String {
        let owned = paints.filter(\.isOwned).count
        return String(localized: "\(paints.count) paints · \(owned) owned")
    }

    // MARK: Actions

    private func setOwned(_ owned: Bool, _ chosen: [Paint]) {
        perform {
            for paint in chosen { try service.setOwned(owned, for: paint) }
        }
    }

    private func delete(_ chosen: [Paint]) {
        var refused: [String] = []
        for paint in chosen {
            do {
                try service.delete(paint)
            } catch {
                refused.append(error.localizedDescription)
            }
        }
        selection.subtract(chosen.map(\.id))
        if !refused.isEmpty {
            alert = (String(localized: "Some Paints Weren't Deleted"), refused.joined(separator: "\n"))
        }
    }

    private func importCSV(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) else {
                throw PaintCSVImporter.ImportError.empty
            }
            let summary = try PaintCSVImporter(context: modelContext).importCSV(text)
            var lines: [String] = []
            if summary.duplicates > 0 {
                lines.append(String(localized: "\(summary.duplicates) were already in your catalogue and were skipped."))
            }
            lines += summary.problems.prefix(10)
            if summary.problems.count > 10 {
                lines.append(String(localized: "…and \(summary.problems.count - 10) more problems."))
            }
            alert = (String(localized: "Imported \(summary.added) Paints"), lines.joined(separator: "\n"))
        } catch {
            alert = (String(localized: "Couldn't Import Paints"), error.localizedDescription)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = (String(localized: "Something Went Wrong"), error.localizedDescription)
        }
    }
}

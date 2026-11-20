import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The library-wide paint catalogue: a sortable table. Searching is done
/// from the window's search field, which covers paints too.
struct PaintCatalogueView: View {
    /// A paint to scroll to and select, e.g. from search. Cleared once shown.
    @Binding var revealID: UUID?

    @Query private var paints: [Paint]
    @Environment(\.modelContext) private var modelContext

    @State private var selection = Set<UUID>()
    @State private var sortOrder = [
        KeyPathComparator(\Paint.brand, comparator: .localizedStandard),
        KeyPathComparator(\Paint.code, comparator: .localizedStandard),
    ]
    @State private var filter = PaintFilter()
    @State private var editorRequest: PaintEditorRequest?
    @State private var isImporting = false
    @State private var isChoosingExport = false
    @State private var exportDocument: TextFileDocument?
    /// Set by the export sheet; the Save dialog opens once the sheet closes.
    @State private var pendingExport: TextFileDocument?
    @State private var pendingDeletion: [Paint] = []
    @State private var alert: (title: String, message: String)?

    private var service: PaintService { PaintService(context: modelContext) }

    private var visiblePaints: [Paint] {
        paints
            .filter { filter.includes(brand: $0.brand, range: $0.range, type: $0.type, isOwned: $0.isOwned) }
            .sorted(using: sortOrder)
    }

    private var brandOptions: [PaintFilterOption] {
        PaintFilterOption.options(for: paints.map(\.brand))
    }

    /// Ranges of the chosen brand, or of every brand.
    private var rangeOptions: [PaintFilterOption] {
        let brandFilter = PaintFilter(brand: filter.brand)
        return PaintFilterOption.options(for: paints
            .filter { brandFilter.includes(brand: $0.brand, range: $0.range, isOwned: $0.isOwned) }
            .map(\.range))
    }

    /// Each type with its count, in menu order, and how many have none.
    private var typeCounts: (types: [(type: PaintType, count: Int)], notSet: Int) {
        var counts: [PaintType: Int] = [:]
        var notSet = 0
        for paint in paints {
            if let type = paint.type { counts[type, default: 0] += 1 } else { notSet += 1 }
        }
        return (PaintType.allCases.compactMap { type in counts[type].map { (type, $0) } }, notSet)
    }

    private var selectedPaints: [Paint] {
        paints.filter { selection.contains($0.id) }
    }

    var body: some View {
        content
            .navigationTitle("Paints")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !paints.isEmpty {
                        filterMenu("Brand", allTitle: "All Brands", options: brandOptions, selection: $filter.brand)
                            .help("Show one brand's paints")
                        filterMenu("Range", allTitle: "All Ranges", options: rangeOptions, selection: $filter.range)
                            .disabled(rangeOptions.isEmpty)
                            .help("Show one range's paints")
                        typeMenu
                            .help("Show one type of paint, such as lacquers")
                    }

                    Toggle(isOn: $filter.ownedOnly) {
                        Label("Owned Only", systemImage: "checkmark.circle")
                    }
                    .help("Show only paints you own")

                    Button("Import CSV…", systemImage: "square.and.arrow.down") { isImporting = true }
                        .help("Import paints from a CSV file")

                    Button("Export CSV…", systemImage: "square.and.arrow.up") { isChoosingExport = true }
                        .disabled(paints.isEmpty)
                        .help("Save the catalogue as a CSV file that another BenchBook can import")

                    Button("Add Mix", systemImage: "flask") { editorRequest = .newMix }
                        .help("Add a custom mix, with a recipe of paints from the catalogue")

                    Button("Add Paint", systemImage: "plus") { editorRequest = .new }
                        .help("Add a paint to the catalogue")
                }
            }
            .sheet(item: $editorRequest) { request in
                PaintEditorView(request: request) { paint in selection = [paint.id] }
            }
            .sheet(isPresented: $isChoosingExport, onDismiss: {
                exportDocument = pendingExport
                pendingExport = nil
            }) {
                NavigationStack {
                    PaintExportSheet(paintCount: paints.filter { !$0.isMix }.count) { options in
                        let csv = PaintCSVExporter.csv(PaintCSVExporter.rows(for: paints), options: options)
                        pendingExport = TextFileDocument(text: csv)
                    }
                }
            }
            // On its own view: two file dialogs on one view can conflict.
            .background {
                Color.clear.fileExporter(
                    isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                    document: exportDocument,
                    contentType: .commaSeparatedText,
                    defaultFilename: PaintCSVExporter.filename()
                ) { result in
                    if case .failure(let error) = result {
                        alert = (String(localized: "Couldn't Export Paints"), error.localizedDescription)
                    }
                }
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
                Text("Paints used in a project or a mix's recipe can't be deleted until they're removed from it.")
            }
            // Choosing another brand, or editing or deleting paints, can
            // leave a brand or range nothing has, which would hide everything.
            .onChange(of: brandOptions.map(\.key) + ["|"] + rangeOptions.map(\.key)) { clearMissingFilters() }
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
                Text("Add the paints you use, or import a CSV file with Brand, Range, Code, Name, Standard, Type, Colour and Owned columns.")
            } actions: {
                Button("Add Paint") { editorRequest = .new }
                    .buttonStyle(.borderedProminent)
                Button("Import CSV…") { isImporting = true }
            }
        } else if visiblePaints.isEmpty, filter == PaintFilter(ownedOnly: true) {
            ContentUnavailableView {
                Label("No Owned Paints", systemImage: "checkmark.circle")
            } description: {
                Text("Mark the paints you have as owned, in the table or when editing a paint.")
            } actions: {
                Button("Show All Paints") { filter = PaintFilter() }
            }
        } else if visiblePaints.isEmpty {
            ContentUnavailableView {
                Label("No Matching Paints", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No paints match the chosen brand, range, type and ownership.")
            } actions: {
                Button("Show All Paints") { filter = PaintFilter() }
            }
        } else {
            table
        }
    }

    private var table: some View {
        ScrollViewReader { proxy in
        Table(visiblePaints, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Swatch") { paint in
                PaintSwatch(hex: paint.swatchHex, isClear: paint.isClear)
            }
            .width(48)
            TableColumn("Brand", value: \.brand, comparator: .localizedStandard)
            TableColumn("Range", value: \.range, comparator: .localizedStandard)
            TableColumn("Code", value: \.code, comparator: .localizedStandard)
                .width(min: 60, ideal: 80)
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { paint in
                HStack(spacing: 6) {
                    Text(paint.name)
                    if paint.isMix {
                        Text("Mix")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(MixAmount.recipeLine(paint.recipeSummary))
                    }
                }
            }
            .width(min: 120, ideal: 200)
            TableColumn("Standard", value: \.standardText, comparator: .localizedStandard)
                .width(min: 70, ideal: 100)
            TableColumn("Match", value: \.matchSortKey) { paint in
                Text(paint.match?.displayName ?? "")
            }
            .width(min: 70, ideal: 100)
            TableColumn("Type", value: \.typeSortKey) { paint in
                Text(paint.type?.displayName ?? "")
                    .help(paint.type?.hint ?? "")
            }
            .width(min: 80, ideal: 150)
            TableColumn("Owned") { paint in
                Toggle("Owned", isOn: Binding(
                    get: { paint.isOwned },
                    set: { owned in perform { try service.setOwned(owned, for: paint) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // A mix is owned when you own its recipe's paints.
                .disabled(paint.isMix)
                .help(paint.isMix ? MixOwnership.help(for: paint) : "")
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
                Button(paint.isMix ? "Edit Mix…" : "Edit Paint…") { editorRequest = .edit(paint) }
            }
            if !chosen.isEmpty {
                let paints = chosen.filter { !$0.isMix }
                if paints.contains(where: { !$0.isOwned }) {
                    Button("Mark as Owned") { setOwned(true, paints) }
                }
                if paints.contains(where: \.isOwned) {
                    Button("Mark as Not Owned") { setOwned(false, paints) }
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
        .onChange(of: revealID, initial: true) { _, id in
            guard let id, let paint = paints.first(where: { $0.id == id }) else { return }
            if !filter.includes(brand: paint.brand, range: paint.range, type: paint.type, isOwned: paint.isOwned) {
                filter = PaintFilter()
            }
            selection = [id]
            proxy.scrollTo(id, anchor: .center)
            revealID = nil
        }
        }
    }

    private var subtitle: String {
        let owned = paints.filter(\.isOwned).count
        guard filter.isActive else { return String(localized: "\(paints.count) paints · \(owned) owned") }
        return String(localized: "\(visiblePaints.count) of \(paints.count) paints · \(owned) owned")
    }

    // MARK: Filters

    /// A toolbar menu naming the chosen brand or range, with paint counts.
    private func filterMenu(
        _ title: LocalizedStringKey, allTitle: LocalizedStringKey,
        options: [PaintFilterOption], selection: Binding<String?>
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                Text(allTitle).tag(String?.none)
                Divider()
                ForEach(options) { option in
                    Text("\(option.name) (\(option.count))").tag(Optional(option.key))
                }
            }
            .pickerStyle(.inline)
        } label: {
            if let key = selection.wrappedValue, let option = options.first(where: { $0.key == key }) {
                Text(option.name)
            } else {
                Text(allTitle)
            }
        }
        .accessibilityLabel(Text(title))
    }

    /// A toolbar menu naming the chosen type, with paint counts.
    private var typeMenu: some View {
        let counts = typeCounts
        return Menu {
            Picker("Type", selection: $filter.type) {
                Text("All Types").tag(PaintFilter.TypeChoice?.none)
                Divider()
                ForEach(counts.types, id: \.type) { entry in
                    Text("\(entry.type.displayName) (\(entry.count))").tag(Optional(PaintFilter.TypeChoice.type(entry.type)))
                }
                if counts.notSet > 0 {
                    Divider()
                    Text("Not Set (\(counts.notSet))").tag(Optional(PaintFilter.TypeChoice.notSet))
                }
            }
            .pickerStyle(.inline)
        } label: {
            switch filter.type {
            case .type(let type)?: Text(type.displayName)
            case .notSet?: Text("Type Not Set")
            case nil: Text("All Types")
            }
        }
        .accessibilityLabel(Text("Type"))
    }

    /// Drops a brand or range no paint has any more.
    private func clearMissingFilters() {
        if let brand = filter.brand, !brandOptions.contains(where: { $0.key == brand }) { filter.brand = nil }
        if let range = filter.range, !rangeOptions.contains(where: { $0.key == range }) { filter.range = nil }
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

/// Chooses what a paint CSV export includes, before the Save dialog.
private struct PaintExportSheet: View {
    let paintCount: Int
    let onExport: (PaintCSVExporter.Options) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = PaintCSVExporter.Options()

    var body: some View {
        Form {
            Section {
                Toggle("Include whether you own each paint", isOn: $options.includesOwnership)
                Toggle("Include notes", isOn: $options.includesNotes)
            } footer: {
                Text("All \(paintCount) paints are saved with their brand, range, code, name, standard, match, type and colour, in a CSV file another BenchBook can import. Mixes aren't included. Leave ownership and notes out when sharing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Export Paints")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export…") {
                    onExport(options)
                    dismiss()
                }
            }
        }
    }
}

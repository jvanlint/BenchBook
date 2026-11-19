import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The library-wide Kits catalogue: one row per physical kit, in a sortable
/// table with filters.
struct KitCatalogueView: View {
    /// A kit to scroll to and select, e.g. from search. Cleared once shown.
    @Binding var revealID: UUID?
    var onShowProject: (Project) -> Void = { _ in }
    /// Opens the new-project sheet with this kit chosen.
    var onNewProject: (Kit) -> Void = { _ in }

    @Query private var kits: [Kit]
    @Query(sort: [SortDescriptor(\Project.name, comparator: .localizedStandard)]) private var projects: [Project]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary

    @State private var selection = Set<UUID>()
    @State private var sortOrder = [
        KeyPathComparator(\Kit.brand, comparator: .localizedStandard),
        KeyPathComparator(\Kit.name, comparator: .localizedStandard),
        KeyPathComparator(\Kit.numberSortKey, comparator: .localizedStandard),
    ]
    @SceneStorage("kits.columns") private var columnCustomization: TableColumnCustomization<Kit>
    @State private var filter = KitFilter()
    @State private var editorRequest: KitEditorView.Request?
    @State private var pendingDeletion: [Kit] = []
    @State private var isImporting = false
    @State private var isChoosingExport = false
    @State private var exportDocument: TextFileDocument?
    /// Set by the export sheet; the Save dialog opens once the sheet closes.
    @State private var pendingExport: TextFileDocument?
    @State private var alert: (title: String, message: String)?

    private var service: KitService { KitService(context: modelContext, library: assetLibrary) }

    /// Copies of a kit stay together, in the order they were added.
    private var visibleKits: [Kit] {
        kits.filter(filter.includes).sorted { lhs, rhs in
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var brandOptions: [PaintFilterOption] {
        PaintFilterOption.options(for: kits.map(\.brand))
    }

    /// Scales of the chosen brand, or of every brand.
    private var scaleOptions: [PaintFilterOption] {
        let brandFilter = KitFilter(brand: filter.brand)
        return PaintFilterOption.options(for: kits.filter(brandFilter.includes).compactMap(\.scale))
    }

    private var selectedKits: [Kit] {
        visibleKits.filter { selection.contains($0.id) }
    }

    var body: some View {
        content
            .navigationTitle("Kits")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !kits.isEmpty {
                        filterMenu("Brand", allTitle: "All Brands", options: brandOptions, selection: $filter.brand)
                            .help("Show one brand's kits")
                        filterMenu("Scale", allTitle: "All Scales", options: scaleOptions, selection: $filter.scale)
                            .disabled(scaleOptions.isEmpty)
                            .help("Show kits in one scale")
                        statusMenu
                        ownershipMenu
                    }

                    Button("Import CSV…", systemImage: "square.and.arrow.down") { isImporting = true }
                        .help("Import kits from a Scalemates stash export or a BenchBook kits file")

                    Button("Export CSV…", systemImage: "square.and.arrow.up") { isChoosingExport = true }
                        .disabled(kits.isEmpty)
                        .help("Save the catalogue as a CSV file that BenchBook can import")

                    Button("Add Kit", systemImage: "plus") { editorRequest = .new }
                        .help("Add a kit to the catalogue")
                }
            }
            .sheet(isPresented: $isChoosingExport, onDismiss: {
                exportDocument = pendingExport
                pendingExport = nil
            }) {
                NavigationStack {
                    KitExportSheet(kitCount: kits.count) { options in
                        pendingExport = TextFileDocument(text: KitCSVExporter.csv(KitCSVExporter.rows(for: kits), options: options))
                    }
                }
            }
            // On its own view: two file dialogs on one view can conflict.
            .background {
                Color.clear.fileExporter(
                    isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                    document: exportDocument,
                    contentType: .commaSeparatedText,
                    defaultFilename: KitCSVExporter.filename()
                ) { result in
                    if case .failure(let error) = result {
                        alert = (String(localized: "Couldn't Export Kits"), error.localizedDescription)
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                if case .success(let url) = result { importCSV(from: url) }
            }
            .sheet(item: $editorRequest) { request in
                NavigationStack {
                    KitEditorView(request: request) { kit in reveal(kit) }
                }
            }
            .confirmationDialog(
                pendingDeletion.count == 1
                    ? "Delete “\(pendingDeletion.first?.displayName ?? "")”?"
                    : "Delete \(pendingDeletion.count) Kits?",
                isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
            ) {
                Button("Delete", role: .destructive) { delete(pendingDeletion) }
            } message: {
                Text(Self.deletionMessage(pendingDeletion))
            }
            // Editing or deleting kits can leave a brand or scale nothing
            // has, which would hide everything.
            .onChange(of: brandOptions.map(\.key) + ["|"] + scaleOptions.map(\.key)) { clearMissingFilters() }
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
        if kits.isEmpty {
            ContentUnavailableView {
                Label("No Kits", systemImage: "shippingbox")
            } description: {
                Text("Add the kits in your stash, and the ones you want, or import a Scalemates stash export. Each box is its own entry, with its own status.")
            } actions: {
                Button("Add Kit") { editorRequest = .new }
                    .buttonStyle(.borderedProminent)
                Button("Import CSV…") { isImporting = true }
            }
        } else if visibleKits.isEmpty {
            ContentUnavailableView {
                Label("No Matching Kits", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No kits match the chosen brand, scale, status and ownership.")
            } actions: {
                Button("Show All Kits") { filter = KitFilter() }
            }
        } else {
            table
        }
    }

    private var table: some View {
        ScrollViewReader { proxy in
        Table(visibleKits, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            identityColumns
            stateColumns
            priceColumns
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: kits.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let kit = kits.first(where: { ids.contains($0.id) }) {
                editorRequest = .edit(kit)
            }
        }
        .onDeleteCommand {
            if !selectedKits.isEmpty { pendingDeletion = selectedKits }
        }
        .onChange(of: revealID, initial: true) { _, id in
            guard let id, let kit = kits.first(where: { $0.id == id }) else { return }
            if !filter.includes(kit) { filter = KitFilter() }
            selection = [id]
            proxy.scrollTo(id, anchor: .center)
            revealID = nil
        }
        }
    }

    /// Picture, brand, name, scale and number. A table builder takes ten
    /// columns at most, so they're in three groups.
    @TableColumnBuilder<Kit, KeyPathComparator<Kit>>
    private var identityColumns: some TableColumnContent<Kit, KeyPathComparator<Kit>> {
        TableColumn("Picture") { kit in
            KitThumbnail(kit: kit)
        }
        .width(40)
        .customizationID("picture")
        TableColumn("Brand", value: \.brand, comparator: .localizedStandard)
            .width(min: 80, ideal: 120)
            .customizationID("brand")
            .disabledCustomizationBehavior(.visibility)
        TableColumn("Name", value: \.name, comparator: .localizedStandard)
            .width(min: 120, ideal: 200)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
        TableColumn("Scale", value: \.scaleSortKey, comparator: .localizedStandard) { kit in
            Text(kit.scale ?? "")
        }
        .width(min: 44, ideal: 56)
        .customizationID("scale")
        TableColumn("Number", value: \.numberSortKey, comparator: .localizedStandard) { kit in
            Text(kit.number ?? "")
        }
        .width(min: 60, ideal: 80)
        .customizationID("number")
    }

    /// Status, rating and project.
    @TableColumnBuilder<Kit, KeyPathComparator<Kit>>
    private var stateColumns: some TableColumnContent<Kit, KeyPathComparator<Kit>> {
        TableColumn("Status", value: \.statusSortKey) { kit in
            if kit.isOwned {
                Text(kit.status.displayName)
                    .help(kit.status.longName)
            } else {
                Text("Not Owned")
                    .foregroundStyle(.secondary)
            }
        }
        .width(min: 60, ideal: 80)
        .customizationID("status")
        TableColumn("Rating", value: \.ratingSortKey) { kit in
            StarRatingLabel(stars: kit.stars)
        }
        .width(min: 70, ideal: 80)
        .customizationID("rating")
        TableColumn("Project", value: \.projectSortKey, comparator: .localizedStandard) { kit in
            if let project = kit.project {
                Text(project.name)
                    .help(kit.isNeeded ? String(localized: "Needed for \(project.name)") : project.name)
            }
        }
        .width(min: 80, ideal: 140)
        .customizationID("project")
    }

    /// Price paid and sale details.
    @TableColumnBuilder<Kit, KeyPathComparator<Kit>>
    private var priceColumns: some TableColumnContent<Kit, KeyPathComparator<Kit>> {
        TableColumn("Price Paid", value: \.pricePaidSortKey) { kit in
            price(kit.pricePaid)
        }
        .width(min: 60, ideal: 80)
        .alignment(.trailing)
        .customizationID("pricePaid")
        TableColumn("For Sale", value: \.forSaleSortKey) { kit in
            Toggle("For Sale", isOn: Binding(
                get: { kit.isForSale },
                set: { forSale in perform { try service.setForSale(forSale, for: [kit]) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("For Sale: \(kit.displayName)")
        }
        .width(56)
        .alignment(.center)
        .customizationID("forSale")
        TableColumn("Sale Price", value: \.salePriceSortKey) { kit in
            price(kit.salePrice)
                .foregroundStyle(kit.isForSale ? .primary : .secondary)
        }
        .width(min: 60, ideal: 80)
        .alignment(.trailing)
        .customizationID("salePrice")
    }

    @ViewBuilder
    private func price(_ amount: Decimal?) -> some View {
        if let amount {
            Text(KitPrice.display(amount))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func menu(for chosen: [Kit]) -> some View {
        if chosen.count == 1, let kit = chosen.first {
            Button("Edit Kit…") { editorRequest = .edit(kit) }
            Button("Add Another Copy") {
                perform { reveal(try service.addCopy(of: kit)) }
            }
            if let link = kit.link {
                Link("Open Link", destination: link)
            }
            if let project = kit.project {
                Button("Show Project") { onShowProject(project) }
            } else {
                Button("New Project from Kit…") { onNewProject(kit) }
            }
            Divider()
        }
        if !chosen.isEmpty {
            Menu("Status") {
                ForEach(KitStatus.allCases) { status in
                    Button(status.displayName) {
                        perform { try service.setStatus(status, for: chosen) }
                    }
                }
            }
            .disabled(!chosen.contains(where: \.isOwned))
            if chosen.contains(where: { !$0.isOwned }) {
                Button("Mark as Owned") { perform { try service.setOwned(true, for: chosen) } }
            }
            if chosen.contains(where: \.isOwned) {
                Button("Mark as Not Owned") { perform { try service.setOwned(false, for: chosen) } }
            }
            if chosen.contains(where: { !$0.isForSale }) {
                Button("Mark as For Sale") { perform { try service.setForSale(true, for: chosen) } }
            }
            if chosen.contains(where: \.isForSale) {
                Button("Mark as Not For Sale") { perform { try service.setForSale(false, for: chosen) } }
            }
            Divider()
            moveMenu(for: chosen)
            let allocated = chosen.filter { $0.project != nil }
            if !allocated.isEmpty {
                Button(allocated.count == 1 ? "Remove from Project" : "Remove \(allocated.count) Kits from Projects") {
                    perform {
                        for kit in allocated {
                            if let project = kit.project { try service.remove([kit], from: project) }
                        }
                    }
                }
            }
            Divider()
            Button(chosen.count == 1 ? "Delete Kit…" : "Delete \(chosen.count) Kits…", role: .destructive) {
                pendingDeletion = chosen
            }
        }
    }

    /// Puts the kits in a project, moving any already in another one.
    private func moveMenu(for chosen: [Kit]) -> some View {
        Menu("Move to Project") {
            ForEach(projects) { project in
                let isHere = chosen.allSatisfy { $0.project?.persistentModelID == project.persistentModelID }
                Button(project.name) {
                    perform { try service.add(chosen, to: project) }
                }
                .disabled(isHere)
            }
        }
        .disabled(projects.isEmpty)
    }

    /// Names the projects using the kits, as deleting takes the kits out of them.
    static func deletionMessage(_ kits: [Kit]) -> String {
        let removes = kits.count == 1
            ? String(localized: "This removes the kit and its picture from BenchBook. This can't be undone.")
            : String(localized: "This removes the kits and their pictures from BenchBook. This can't be undone.")
        var names: [String] = []
        for name in kits.compactMap(\.project?.name) where !names.contains(name) { names.append(name) }
        guard !names.isEmpty else { return removes }
        let used = names.count == 1
            ? String(localized: "It's used by the project “\(names[0])”.")
            : String(localized: "They're used by the projects \(names.map { "“\($0)”" }.formatted(.list(type: .and))).")
        return used + " " + removes
    }

    /// e.g. "116 kits · 4 not owned", or "12 of 116 kits · 4 not owned".
    private var subtitle: String {
        let notOwned = kits.filter { !$0.isOwned }.count
        let total = String(AttributedString(localized: "^[\(kits.count) kit](inflect: true)").inflected().characters)
        let counted = filter.isActive ? String(localized: "\(visibleKits.count) of \(total)") : total
        return notOwned == 0 ? counted : String(localized: "\(counted) · \(notOwned) not owned")
    }

    // MARK: Filters

    /// A toolbar menu naming the chosen brand or scale, with kit counts.
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

    /// Only owned kits have a status, so the counts are of owned kits.
    private var statusMenu: some View {
        Menu {
            Picker("Status", selection: $filter.status) {
                Text("Any Status").tag(KitStatus?.none)
                Divider()
                ForEach(KitStatus.allCases) { status in
                    let count = kits.filter { $0.isOwned && $0.status == status }.count
                    Text("\(status.displayName) (\(count))").tag(Optional(status))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(filter.status?.displayName ?? String(localized: "Any Status"))
        }
        .accessibilityLabel("Status")
        .help("Show owned kits with one status")
    }

    private var ownershipMenu: some View {
        Menu {
            Picker("Show", selection: $filter.ownership) {
                ForEach(KitFilter.Ownership.allCases) { ownership in
                    Text(ownership.displayName).tag(ownership)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(filter.ownership.displayName)
        }
        .accessibilityLabel("Show")
        .help("Show all kits, owned kits, kits you don't own yet, kits for sale, kits not in a project, or kits needed for a build")
    }

    /// Drops a brand or scale no kit has any more.
    private func clearMissingFilters() {
        if let brand = filter.brand, !brandOptions.contains(where: { $0.key == brand }) { filter.brand = nil }
        if let scale = filter.scale, !scaleOptions.contains(where: { $0.key == scale }) { filter.scale = nil }
    }

    // MARK: Actions

    /// Selects the kit, showing every kit if the filters would hide it.
    private func reveal(_ kit: Kit) {
        revealID = kit.id
    }

    private func delete(_ chosen: [Kit]) {
        perform { try service.delete(chosen) }
        selection.subtract(chosen.map(\.id))
    }

    private func importCSV(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) else {
                throw KitCSVImporter.ImportError.empty
            }
            let summary = try KitCSVImporter(context: modelContext).importCSV(text)
            alert = (Self.importTitle(summary), Self.importMessage(summary))
        } catch {
            alert = (String(localized: "Couldn't Import Kits"), error.localizedDescription)
        }
    }

    /// e.g. "Added 3 Kits and Updated 1".
    static func importTitle(_ summary: KitCSVImporter.Summary) -> String {
        let added = String(AttributedString(localized: "^[\(summary.added) Kit](inflect: true)").inflected().characters)
        switch (summary.added, summary.updated) {
        case (0, 0): return String(localized: "No Kits Added")
        case (_, 0): return String(localized: "Added \(added)")
        case (0, let updated): return String(AttributedString(localized: "Updated ^[\(updated) Kit](inflect: true)").inflected().characters)
        default: return String(localized: "Added \(added) and Updated \(summary.updated)")
        }
    }

    /// The rest of the summary: kits already there, rows skipped, problems.
    static func importMessage(_ summary: KitCSVImporter.Summary) -> String {
        var lines: [String] = []
        if summary.unchanged > 0 {
            lines.append(String(localized: "Already in your catalogue: \(summary.unchanged)."))
        }
        if summary.skippedCount > 0 {
            let types = summary.skipped.map { "\($0.type) \($0.count)" }.formatted(.list(type: .and, width: .narrow))
            lines.append(String(localized: "\(summary.skippedCount) rows skipped that aren't kits: \(types)."))
        }
        lines += summary.problems.prefix(10)
        if summary.problems.count > 10 {
            lines.append(String(localized: "…and \(summary.problems.count - 10) more problems."))
        }
        return lines.joined(separator: "\n")
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = (String(localized: "Something Went Wrong"), error.localizedDescription)
        }
    }
}

/// Chooses what a kit CSV export includes, before the Save dialog.
private struct KitExportSheet: View {
    let kitCount: Int
    let onExport: (KitCSVExporter.Options) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = KitCSVExporter.Options()

    var body: some View {
        Form {
            Section {
                Toggle("Include notes", isOn: $options.includesNotes)
            } footer: {
                Text("All \(kitCount) kits are saved, one row each, with their details, status, rating, prices and links, in a CSV file BenchBook can import. Pictures aren't included; a backup has them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Export Kits")
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

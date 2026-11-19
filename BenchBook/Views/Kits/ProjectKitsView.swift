import SwiftData
import SwiftUI

/// A Project's Kits section: the kits from the catalogue this build uses.
/// Removing a kit from the project never deletes it.
struct ProjectKitsView: View {
    let project: Project
    /// Shows a kit in the Kits catalogue.
    let onShowKit: (Kit) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openURL) private var openURL

    @State private var selection = Set<UUID>()
    @State private var sortOrder: [KeyPathComparator<Kit>] = []
    @State private var editor: KitEditorView.Request?
    @State private var isPicking = false
    @State private var errorMessage: String?

    private var service: KitService { KitService(context: modelContext, library: assetLibrary) }

    private var rows: [Kit] {
        // Ties keep the order they were added.
        sortOrder.isEmpty ? project.sortedKits : project.sortedKits.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if project.kits.isEmpty {
                ContentUnavailableView {
                    Label("No Kits", systemImage: "shippingbox")
                } description: {
                    Text("Choose the kits for this build from your Kits catalogue, or add a new one.")
                } actions: {
                    Button("Add from Kits…") { isPicking = true }
                    Button("New Kit…") { editor = .new }
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    table
                }
            }
        }
        .sheet(item: $editor) { request in
            NavigationStack {
                KitEditorView(request: request, project: project) { kit in selection = [kit.id] }
            }
        }
        .sheet(isPresented: $isPicking) {
            KitPickerView(projectName: project.name) { kits in
                try service.add(kits, to: project)
                selection = Set(kits.map(\.id))
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(Self.counted(AttributedString(localized: "^[\(project.kits.count) kit](inflect: true)")))
            let notOwned = project.kits.filter { !$0.isOwned }.count
            if notOwned > 0 {
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(notOwned) not owned")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add from Kits…", systemImage: "plus") { isPicking = true }
                .help("Choose kits for this build from your Kits catalogue")
            Button("New Kit…", systemImage: "shippingbox") { editor = .new }
                .help("Add a kit to your catalogue and to this build")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private static func counted(_ text: AttributedString) -> String {
        String(text.inflected().characters)
    }

    // MARK: Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Picture") { kit in
                KitThumbnail(kit: kit, size: 36)
            }
            .width(48)
            TableColumn("Kit", value: \.name, comparator: .localizedStandard) { kit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(kit.name)
                    Text([kit.brand, kit.number ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(kit.notes ?? "")
            }
            .width(min: 160, ideal: 260)
            TableColumn("Scale", value: \.scaleSortKey, comparator: .localizedStandard) { kit in
                Text(kit.scale ?? "")
            }
            .width(min: 44, ideal: 60)
            TableColumn("Status", value: \.statusSortKey) { kit in
                if kit.isOwned {
                    statusPicker(for: kit)
                } else {
                    Text("Not Owned")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Link") { kit in
                if let url = kit.link {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(url.host() ?? url.absoluteString)")
                    .accessibilityLabel("Open Link")
                }
            }
            .width(36)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let kit = rows.first(where: { ids.contains($0.id) }) { editor = .edit(kit) }
        }
        // Delete only takes kits out of the project, so it doesn't ask.
        .onDeleteCommand {
            let chosen = rows.filter { selection.contains($0.id) }
            if !chosen.isEmpty { remove(chosen) }
        }
    }

    private func statusPicker(for kit: Kit) -> some View {
        Picker("Status", selection: Binding(
            get: { kit.status },
            set: { status in perform { try service.setStatus(status, for: [kit]) } }
        )) {
            ForEach(KitStatus.allCases) { status in
                Text(status.displayName).tag(status)
                    .help(status.longName)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .accessibilityLabel("Status of \(kit.displayName)")
    }

    @ViewBuilder
    private func menu(for chosen: [Kit]) -> some View {
        if chosen.count == 1, let kit = chosen.first {
            Button("Edit Kit…") { editor = .edit(kit) }
            Button("Show in Kits") { onShowKit(kit) }
            if let link = kit.link {
                Button("Open Link") { openURL(link) }
            }
            Divider()
        }
        let owned = chosen.filter(\.isOwned)
        if !owned.isEmpty {
            Picker("Status", selection: Binding(
                get: { Set(owned.map(\.statusRaw)).count == 1 ? owned[0].status : nil },
                set: { status in
                    if let status { perform { try service.setStatus(status, for: owned) } }
                }
            )) {
                ForEach(KitStatus.allCases) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
        }
        if !chosen.isEmpty {
            Divider()
            Button(chosen.count == 1 ? "Remove from Project" : "Remove \(chosen.count) Kits from Project") {
                remove(chosen)
            }
        }
    }

    private func remove(_ kits: [Kit]) {
        selection.subtract(kits.map(\.id))
        perform { try service.remove(kits, from: project) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet for choosing catalogue kits for a project. Only kits that aren't in
/// a project are listed, as each kit is one box.
struct KitPickerView: View {
    /// For the title, e.g. "Add Kits to Cobra". Nil for a project not yet created.
    let projectName: String?
    /// Kits already chosen, e.g. in the new-project sheet, which aren't listed.
    var excluding: Set<UUID> = []
    /// Called with the chosen kits. An error is shown and the sheet stays open.
    let onChoose: ([Kit]) throws -> Void

    @Query(filter: #Predicate<Kit> { $0.project == nil }, sort: \Kit.createdAt)
    private var unallocatedKits: [Kit]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var chosen = Set<UUID>()
    @State private var searchText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// By brand, then name, then the order they were added.
    private var unallocated: [Kit] {
        unallocatedKits.filter { !excluding.contains($0.id) }.sorted { lhs, rhs in
            for (a, b) in [(lhs.brand, rhs.brand), (lhs.name, rhs.name)] {
                let result = a.localizedStandardCompare(b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
    }

    private var candidates: [Kit] {
        let words = searchText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return unallocated }
        return unallocated.filter { kit in
            let text = [kit.brand, kit.name, kit.scale ?? "", kit.number ?? ""].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private var addTitle: String {
        chosen.count > 1 ? String(localized: "Add \(chosen.count) Kits") : String(localized: "Add Kit")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(projectName.map { String(localized: "Add Kits to \($0)") } ?? String(localized: "Choose Kits"))
                .font(.headline)
                .padding(.top, 16)
            TextField("Search", text: $searchText, prompt: Text("Search brand, name, scale or number"))
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if candidates.isEmpty {
                ContentUnavailableView {
                    Label(unallocated.isEmpty ? "No Kits to Add" : "No Matching Kits", systemImage: "shippingbox")
                } description: {
                    Text(unallocated.isEmpty
                         ? "Every kit in your catalogue is already in a project. Add a new one here, or import your stash from Kits in the sidebar."
                         : "No kit that isn't already in a project matches “\(searchText)”.")
                } actions: {
                    Button("New Kit…") { isCreating = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(candidates) { kit in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(kit.id) },
                        set: { on in if on { chosen.insert(kit.id) } else { chosen.remove(kit.id) } }
                    )) {
                        HStack(spacing: 8) {
                            KitThumbnail(kit: kit)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kit.name)
                                Text([kit.brand, kit.scale ?? "", kit.number ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(kit.isOwned ? kit.status.displayName : String(localized: "Not Owned"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()
            HStack {
                Button("New Kit…") { isCreating = true }
                    .help("Add a kit to your catalogue. It's ticked here, ready to add.")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle, action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 540)
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                KitEditorView(request: .new) { kit in chosen.insert(kit.id) }
            }
        }
        .alert(
            "Couldn't Add Kits",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add() {
        let kits = unallocated.filter { chosen.contains($0.id) }
        do {
            try onChoose(kits)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

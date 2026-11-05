import SwiftData
import SwiftUI

/// A Project's Aftermarket section: decals, resin, photo-etch and other
/// parts for this build, and where each one stands.
struct ProjectAftermarketView: View {
    let project: Project
    /// A part to select, e.g. from search. Cleared once shown.
    @Binding var revealID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.openURL) private var openURL

    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\AftermarketItem.statusRank)]
    @State private var editor: AftermarketEditorView.Request?
    @State private var pendingDeletion: [AftermarketItem] = []
    @State private var errorMessage: String?

    private var service: AftermarketService {
        AftermarketService(context: modelContext, library: assetLibrary)
    }

    private var rows: [AftermarketItem] {
        // Ties keep the default order: status, then name.
        project.sortedAftermarketItems.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if project.aftermarketItems.isEmpty {
                ContentUnavailableView {
                    Label("No Aftermarket Parts", systemImage: "shippingbox")
                } description: {
                    Text("Keep track of decals, resin, photo-etch and other parts you're using or considering for this build.")
                } actions: {
                    Button("Add Part…") { editor = .new(project) }
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
            NavigationStack { AftermarketEditorView(request: request) }
        }
        .onChange(of: revealID, initial: true) { _, id in
            guard let id else { return }
            selection = [id]
            revealID = nil
        }
        .confirmationDialog(
            pendingDeletion.count == 1
                ? "Delete “\(pendingDeletion.first?.productName ?? "")”?"
                : "Delete \(pendingDeletion.count) Parts?",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) {
                let chosen = pendingDeletion
                selection.subtract(chosen.map(\.id))
                perform { try service.delete(chosen) }
            }
        } message: {
            Text("Their details and pictures are removed from this project.")
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
            Text("\(project.aftermarketItems.count) parts")
            ForEach(statusCounts, id: \.status) { entry in
                Text("·")
                    .foregroundStyle(.secondary)
                Label("\(entry.count) \(entry.status.displayName.lowercased())", systemImage: entry.status.systemImage)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Part…", systemImage: "plus") { editor = .new(project) }
                .help("Add decals, resin or other parts for this build")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// Parts still to sort out: considering and ordered.
    private var statusCounts: [(status: AftermarketStatus, count: Int)] {
        [AftermarketStatus.considering, .ordered].compactMap { status in
            let count = project.aftermarketItems.filter { $0.status == status }.count
            return count > 0 ? (status, count) : nil
        }
    }

    // MARK: Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Picture") { item in
                AftermarketThumbnail(item: item)
            }
            .width(48)
            TableColumn("Part", value: \.productName, comparator: .localizedStandard) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.productName)
                    if !item.secondaryLine.isEmpty {
                        Text(item.secondaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(item.notes ?? "")
            }
            .width(min: 160, ideal: 260)
            TableColumn("Type", value: \.typeName, comparator: .localizedStandard) { item in
                Text(item.typeName)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Scale or Fits") { item in
                Text(item.scaleCompatibility ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Status", value: \.statusRank) { item in
                statusPicker(for: item)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Link") { item in
                if let url = item.productURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(url.host() ?? url.absoluteString)")
                    .accessibilityLabel("Open Product Page")
                }
            }
            .width(36)
        }
        .contextMenu(forSelectionType: AftermarketItem.ID.self) { ids in
            menu(for: rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = rows.first(where: { ids.contains($0.id) }) { editor = .edit(item) }
        }
        .onDeleteCommand {
            let chosen = rows.filter { selection.contains($0.id) }
            if !chosen.isEmpty { pendingDeletion = chosen }
        }
    }

    private func statusPicker(for item: AftermarketItem) -> some View {
        Picker("Status", selection: Binding(
            get: { item.status ?? .considering },
            set: { status in perform { try service.setStatus(status, for: [item]) } }
        )) {
            ForEach(AftermarketStatus.allCases) { status in
                Label(status.displayName, systemImage: status.systemImage).tag(status)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .accessibilityLabel("Status of \(item.productName)")
    }

    @ViewBuilder
    private func menu(for chosen: [AftermarketItem]) -> some View {
        if chosen.count == 1, let item = chosen.first {
            Button("Edit…") { editor = .edit(item) }
            if let url = item.productURL {
                Button("Open Product Page") { openURL(url) }
            }
        }
        if !chosen.isEmpty {
            Picker("Status", selection: Binding(
                get: { Set(chosen.map(\.statusRaw)).count == 1 ? chosen[0].status : nil },
                set: { status in
                    if let status { perform { try service.setStatus(status, for: chosen) } }
                }
            )) {
                ForEach(AftermarketStatus.allCases) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            Divider()
            Button(chosen.count == 1 ? "Delete Part…" : "Delete \(chosen.count) Parts…", role: .destructive) {
                pendingDeletion = chosen
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

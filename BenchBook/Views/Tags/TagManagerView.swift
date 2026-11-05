import SwiftData
import SwiftUI

/// Every tag in the library, with where it's used. Rename, recolour,
/// merge and delete tags here.
struct TagManagerView: View {
    let onShowTag: (Tag) -> Void

    @Query private var tags: [Tag]
    @Environment(\.modelContext) private var modelContext

    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Tag.usageCount, order: .reverse)]
    @State private var nameSheet: TagNameSheet.Mode?
    @State private var pendingMerge: [Tag] = []
    @State private var pendingDeletion: [Tag] = []
    @State private var errorMessage: String?

    private var service: TagService { TagService(context: modelContext) }

    private var sortedTags: [Tag] {
        // Ties keep a stable, alphabetical order.
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .sorted(using: sortOrder)
    }

    private var unusedCount: Int {
        tags.filter { $0.referenceLinks.isEmpty }.count
    }

    var body: some View {
        content
            .navigationTitle("Tags")
            .navigationSubtitle(String(localized: "\(tags.count) tags"))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Remove Unused Tags", systemImage: "tag.slash") { perform { try service.removeUnused() } }
                        .disabled(unusedCount == 0)
                        .help(unusedCount == 0 ? "Every tag is in use" : "Delete the \(unusedCount) tags no reference uses")
                    Button("New Tag", systemImage: "plus") { nameSheet = .new }
                        .help("Add a tag, to drag onto references")
                }
            }
            .sheet(item: $nameSheet) { mode in
                NavigationStack { TagNameSheet(mode: mode) }
            }
            .confirmationDialog(
                "Merge \(pendingMerge.count) Tags?",
                isPresented: Binding(get: { !pendingMerge.isEmpty }, set: { if !$0 { pendingMerge = [] } })
            ) {
                ForEach(pendingMerge.sorted(by: Tag.byUsage)) { tag in
                    Button("Keep “\(tag.name)”") { merge(into: tag) }
                }
            } message: {
                Text("References with any of these tags will have the one you keep. The others are deleted.")
            }
            .confirmationDialog(
                pendingDeletion.count == 1
                    ? "Delete “\(pendingDeletion.first?.name ?? "")”?"
                    : "Delete \(pendingDeletion.count) Tags?",
                isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
            ) {
                Button("Delete", role: .destructive) {
                    let chosen = pendingDeletion
                    perform { try service.delete(chosen) }
                    selection.subtract(chosen.map(\.id))
                }
            } message: {
                Text(deletionMessage)
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

    @ViewBuilder
    private var content: some View {
        if tags.isEmpty {
            ContentUnavailableView {
                Label("No Tags", systemImage: "tag")
            } description: {
                Text("Tags you add to references appear here, where you can rename, colour, merge and delete them.")
            } actions: {
                Button("New Tag") { nameSheet = .new }
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(sortedTags, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Colour") { tag in
                TagColorButton(tag: tag)
            }
            .width(50)
            TableColumn("Name", value: \.name, comparator: .localizedStandard)
                .width(min: 120, ideal: 200)
            TableColumn("References", value: \.usageCount) { tag in
                Text(tag.usageCount, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(tag.usageCount == 0 ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Projects") { tag in
                Text(tag.projectNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let chosen = tags.filter { ids.contains($0.id) }
            if chosen.count == 1, let tag = chosen.first {
                Button("Show References") { onShowTag(tag) }
                Button("Rename…") { nameSheet = .rename(tag) }
            }
            if !chosen.isEmpty {
                TagColorPicker(tags: chosen)
                if chosen.count > 1 {
                    Button("Merge \(chosen.count) Tags…") { pendingMerge = chosen }
                }
                Divider()
                Button(chosen.count == 1 ? "Delete Tag…" : "Delete \(chosen.count) Tags…", role: .destructive) {
                    pendingDeletion = chosen
                }
            }
        } primaryAction: { ids in
            if let tag = tags.first(where: { ids.contains($0.id) }) { onShowTag(tag) }
        }
        .onDeleteCommand {
            let chosen = tags.filter { selection.contains($0.id) }
            if !chosen.isEmpty { pendingDeletion = chosen }
        }
    }

    private var deletionMessage: String {
        let references = Set(pendingDeletion.flatMap { $0.references.map(\.id) }).count
        return references == 0
            ? String(localized: "No references use them.")
            : String(localized: "They'll be removed from \(references) references. The references themselves aren't deleted.")
    }

    private func merge(into target: Tag) {
        let sources = pendingMerge.filter { $0.id != target.id }
        perform { try service.merge(sources, into: target) }
        selection = [target.id]
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

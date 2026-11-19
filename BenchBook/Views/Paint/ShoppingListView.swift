import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Library › Shopping List: kits and paints you don't own that a project
/// which isn't Completed needs. Ticking one marks it owned.
struct ShoppingListView: View {
    /// Shows a paint in the Paints catalogue.
    let onShowInPaints: (UUID) -> Void
    var onShowKit: (Kit) -> Void = { _ in }
    var onShowProject: (Project) -> Void = { _ in }

    @Query private var selections: [ProjectPaint]
    @Query(filter: #Predicate<Kit> { !$0.isOwned && $0.project != nil }) private var kitsNotOwned: [Kit]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary

    @State private var exportDocument: TextFileDocument?
    @State private var errorMessage: String?

    private var list: PaintShoppingList { PaintShoppingList(selections: selections) }

    /// By project, then brand and name.
    private var neededKits: [Kit] {
        kitsNotOwned.filter(\.isNeeded).sorted { lhs, rhs in
            for (a, b) in [(lhs.project?.name ?? "", rhs.project?.name ?? ""), (lhs.brand, rhs.brand), (lhs.name, rhs.name)] {
                let result = a.localizedStandardCompare(b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        let list = list
        let kits = neededKits
        Group {
            if list.isEmpty && kits.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Buy", systemImage: "cart")
                } description: {
                    Text("Kits and paints you don't own that a project needs appear here, with colours that have no paint chosen yet. Completed projects aren't included.")
                }
            } else {
                List {
                    if !kits.isEmpty {
                        Section("Kits") {
                            ForEach(kits) { kit in
                                row(for: kit)
                            }
                        }
                    }
                    ForEach(list.groups) { group in
                        Section(group.name) {
                            ForEach(group.items) { item in
                                row(for: item)
                            }
                        }
                    }
                    if !list.unchosen.isEmpty {
                        Section(PaintShoppingList.unchosenHeading) {
                            ForEach(list.unchosen) { colour in
                                row(for: colour)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Shopping List")
        .navigationSubtitle(Self.summary(kits: kits.count, paints: list))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export Shopping List…", systemImage: "square.and.arrow.up") {
                    exportDocument = TextFileDocument(text: Self.text(kits: kits, paints: list))
                }
                .disabled(list.isEmpty && kits.isEmpty)
                .help("Save the shopping list as a text file")
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: PaintShoppingList.filename()
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
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

    private func row(for kit: Kit) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("Bought", isOn: Binding(get: { false }, set: { bought in if bought { markBought(kit) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Mark as bought: it's owned, BNIB, and off the list")
                .accessibilityLabel("Mark \(kit.displayName) as Bought")
            KitThumbnail(kit: kit)
            VStack(alignment: .leading, spacing: 2) {
                Text(kit.name)
                Text([kit.brand, kit.scale ?? "", kit.number ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(kit.project?.name ?? "")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Mark as Bought") { markBought(kit) }
            Button("Show in Kits") { onShowKit(kit) }
            if let project = kit.project {
                Button("Show Project") { onShowProject(project) }
            }
        }
    }

    private func markBought(_ kit: Kit) {
        do {
            try KitService(context: modelContext, library: assetLibrary).markBought([kit])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// e.g. "2 kits · 9 paints for 3 projects".
    static func summary(kits: Int, paints: PaintShoppingList) -> String {
        var parts: [String] = []
        if kits > 0 { parts.append(String(AttributedString(localized: "^[\(kits) kit](inflect: true)").inflected().characters)) }
        if !paints.isEmpty { parts.append(paints.summary) }
        return parts.joined(separator: " · ")
    }

    /// The list as text, needed kits first (`PaintShoppingList.text`).
    static func text(kits: [Kit], paints: PaintShoppingList, on date: Date = .now) -> String {
        paints.text(on: date, kits: kits.map { kit in
            PaintShoppingList.KitLine(
                title: ["\(kit.brand) \(kit.name)", kit.scale ?? "", kit.number ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                project: kit.project?.name ?? ""
            )
        })
    }

    private func row(for item: PaintShoppingList.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Owned", isOn: Binding(get: { false }, set: { owned in if owned { markOwned(item) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Mark as owned and take it off the list")
                .accessibilityLabel("Mark \(item.title) as Owned")
            PaintSwatch(hex: item.swatchHex)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(item.usesLine)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Mark as Owned") { markOwned(item) }
            Button("Show in Paints") { onShowInPaints(item.id) }
        }
    }

    /// Choose a paint for these on the project's Paint tab.
    private func row(for colour: PaintShoppingList.Colour) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PaintSwatch(hex: nil)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(colour.standard)
            Spacer(minLength: 12)
            Text(colour.useLine)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
        .padding(.leading, 26)
        .help("Choose a paint for this colour on the project's Paint tab")
    }

    private func markOwned(_ item: PaintShoppingList.Item) {
        guard let paint = selections.lazy.compactMap(\.selectedPaint).first(where: { $0.id == item.id }) else { return }
        do {
            try PaintService(context: modelContext).setOwned(true, for: paint)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

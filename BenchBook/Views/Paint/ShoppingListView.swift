import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Library › Shopping List: paints you don't own that a project which
/// isn't Completed needs, by brand. Ticking one marks it owned.
struct ShoppingListView: View {
    /// Shows a paint in the Paints catalogue.
    let onShowInPaints: (UUID) -> Void

    @Query private var selections: [ProjectPaint]
    @Environment(\.modelContext) private var modelContext

    @State private var exportDocument: TextFileDocument?
    @State private var errorMessage: String?

    private var list: PaintShoppingList { PaintShoppingList(selections: selections) }

    var body: some View {
        let list = list
        Group {
            if list.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Buy", systemImage: "cart")
                } description: {
                    Text("Paints you don't own that a project needs appear here. Completed projects aren't included.")
                }
            } else {
                List {
                    ForEach(list.groups) { group in
                        Section(group.name) {
                            ForEach(group.items) { item in
                                row(for: item)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Shopping List")
        .navigationSubtitle(list.isEmpty ? "" : list.summary)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export Shopping List…", systemImage: "square.and.arrow.up") {
                    exportDocument = TextFileDocument(text: list.text())
                }
                .disabled(list.isEmpty)
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

    private func markOwned(_ item: PaintShoppingList.Item) {
        guard let paint = selections.lazy.compactMap(\.selectedPaint).first(where: { $0.id == item.id }) else { return }
        do {
            try PaintService(context: modelContext).setOwned(true, for: paint)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

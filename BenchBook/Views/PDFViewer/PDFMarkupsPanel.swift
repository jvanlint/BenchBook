import SwiftUI

/// The PDF viewer's side panel: one numbered, editable row per markup,
/// grouped by page.
struct PDFMarkupsPanel: View {
    /// In page order, which is also their number.
    let markups: [Markup]
    @Binding var selection: UUID?
    /// Set to a markup's ID to move the cursor into its text.
    @Binding var markupToFocus: UUID?
    let service: MarkupService
    let onSetColor: (Markup, MarkupColor) -> Void
    let onDelete: (Markup) -> Void

    @FocusState private var focusedMarkup: UUID?

    private struct PageGroup: Identifiable {
        let pageIndex: Int
        let rows: [(number: Int, markup: Markup)]
        var id: Int { pageIndex }
    }

    private var pages: [PageGroup] {
        let numbered = markups.enumerated().map { (number: $0.offset + 1, markup: $0.element) }
        return Dictionary(grouping: numbered, by: \.markup.pageIndex)
            .map { PageGroup(pageIndex: $0.key, rows: $0.value) }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    var body: some View {
        Group {
            if markups.isEmpty {
                ContentUnavailableView {
                    Label("No Markups", systemImage: "highlighter")
                } description: {
                    Text("Choose Note, Highlight or Arrow in the toolbar, then click or drag on a page.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(pages) { page in
                        Section("Page \(page.pageIndex + 1)") {
                            ForEach(page.rows, id: \.markup.id) { row in
                                self.row(row.markup, number: row.number)
                                    .tag(row.markup.id)
                                    .contextMenu { menu(for: row.markup) }
                            }
                        }
                    }
                }
                .onDeleteCommand {
                    if let markup = markups.first(where: { $0.id == selection }) { onDelete(markup) }
                }
            }
        }
        .onChange(of: markupToFocus) { _, id in
            guard let id else { return }
            focusedMarkup = id
            markupToFocus = nil
        }
        .onChange(of: focusedMarkup) { old, new in
            if let new { selection = new }
            if old != nil { try? service.commit() }
        }
    }

    private func row(_ markup: Markup, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 20, minHeight: 20)
                .background(selection == markup.id ? Color.accentColor : Color(nsColor: markup.color.nsColor), in: Circle())
                .foregroundStyle(selection == markup.id || ![.yellow, .green].contains(markup.color) ? .white : .black)
                .accessibilityLabel("\(markup.kind.displayName) \(number)")

            Image(systemName: markup.kind.systemImage)
                .foregroundStyle(.secondary)
                .help(markup.kind.displayName)

            TextField(
                "\(markup.kind.displayName) \(number)",
                text: Binding(get: { markup.text }, set: { service.setText($0, on: markup) }),
                prompt: Text(prompt(for: markup.kind)),
                axis: .vertical
            )
            .lineLimit(1...8)
            .textFieldStyle(.plain)
            .focused($focusedMarkup, equals: markup.id)
            .onSubmit { try? service.commit() }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func menu(for markup: Markup) -> some View {
        Picker("Colour", selection: Binding(get: { markup.color }, set: { onSetColor(markup, $0) })) {
            ForEach(MarkupColor.allCases) { color in
                Label { Text(color.displayName) } icon: { Image(nsImage: color.swatch) }
                    .tag(color)
            }
        }
        Divider()
        Button("Delete \(markup.kind.displayName)…", role: .destructive) { onDelete(markup) }
    }

    private func prompt(for kind: MarkupKind) -> String {
        switch kind {
        case .note: String(localized: "Write a note")
        case .highlight: String(localized: "Describe this highlight")
        case .arrow: String(localized: "What does it point to?")
        }
    }
}

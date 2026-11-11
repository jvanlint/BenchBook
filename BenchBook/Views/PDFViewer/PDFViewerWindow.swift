import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Root of a PDF viewer window. The window's value is the Reference ID,
/// so previous/next simply changes it.
struct PDFViewerWindow: View {
    static let id = "pdf-viewer"

    @Binding var referenceID: UUID?
    @Environment(\.modelContext) private var modelContext

    private var reference: Reference? {
        guard let referenceID else { return nil }
        return try? modelContext.fetch(FetchDescriptor<Reference>(predicate: #Predicate { $0.id == referenceID })).first
    }

    var body: some View {
        if let reference, reference.kind == .pdf {
            PDFViewer(reference: reference) { referenceID = $0 }
                .id(reference.id)
        } else {
            ContentUnavailableView(
                "PDF Not Found",
                systemImage: "doc.badge.ellipsis",
                description: Text("This PDF may have been deleted.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Asks a PDF viewer to show one of its markups, e.g. from search.
/// Keyed by Reference ID; the viewer clears the request once shown.
@Observable
final class PDFViewerRequests {
    static let shared = PDFViewerRequests()
    var markupToShow: [UUID: UUID] = [:]
}

/// Why a reference's PDF can't be shown, in words for the user.
nonisolated enum PDFLoadError: LocalizedError, Equatable {
    case noFile, missingFile, unreadable, locked

    var errorDescription: String? {
        switch self {
        case .noFile: String(localized: "This reference has no saved PDF.")
        case .missingFile: String(localized: "The saved copy of this PDF is missing from the library.")
        case .unreadable: String(localized: "The saved copy of this PDF can't be read.")
        case .locked: String(localized: "This PDF is protected with a password, so BenchBook can't show it. Use Open in Default App instead.")
        }
    }
}

extension PDFDocument {
    /// Loads a reference's saved PDF. The file is read into memory, so the
    /// library's copy is never held open or written to.
    static func load(_ reference: Reference, from library: AssetLibrary) async throws -> PDFDocument {
        guard let asset = reference.asset else { throw PDFLoadError.noFile }
        let url = library.url(forRelativePath: asset.originalRelativePath)
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        } catch {
            throw FileManager.default.fileExists(atPath: url.path) ? PDFLoadError.unreadable : PDFLoadError.missingFile
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw PDFLoadError.unreadable }
        guard !document.isLocked else { throw PDFLoadError.locked }
        return document
    }
}

extension MarkupExporter {
    /// Asks where to save, then writes a separate PDF with the reference's
    /// markups drawn in. The library's copy is untouched. Does nothing if
    /// the user cancels.
    static func saveMarkedUpCopy(of reference: Reference, from library: AssetLibrary) async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = String(localized: "\(reference.displayTitle) (Marked Up)")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            // A fresh copy, so no viewer's on-screen markups are part of it.
            let source = try await PDFDocument.load(reference, from: library)
            guard let data = markedUpData(of: source, markups: MarkupItem.items(for: reference.sortedMarkups)) else {
                throw PDFLoadError.unreadable
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ExportError(underlying: error)
        }
    }

    struct ExportError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            String(localized: "The marked-up copy couldn't be saved. \(underlying.localizedDescription)")
        }
    }
}

/// Shows one PDF with page thumbnails, zoom, Find and markups.
struct PDFViewer: View {
    let reference: Reference
    let onNavigate: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary

    @State private var controller = PDFViewerController()
    @State private var isLoaded = false
    @State private var loadError: String?
    @State private var findText = ""
    @FocusState private var isFindFocused: Bool
    @AppStorage("pdfViewer.showsThumbnails") private var showsThumbnails = true
    @AppStorage("pdfViewer.showsMarkupsPanel") private var showsPanel = true
    @AppStorage("pdfViewer.noteColor") private var noteColor = MarkupKind.note.defaultColor
    @AppStorage("pdfViewer.highlightColor") private var highlightColor = MarkupKind.highlight.defaultColor
    @AppStorage("pdfViewer.arrowColor") private var arrowColor = MarkupKind.arrow.defaultColor
    @State private var markupToFocus: UUID?
    @State private var markupPendingDeletion: Markup?
    @State private var errorMessage: String?

    private var service: MarkupService { MarkupService(context: modelContext) }

    private var markups: [Markup] { reference.sortedMarkups }

    /// PDFs in the same Project, newest first, as in the gallery.
    private var siblings: [Reference] {
        (reference.project?.references ?? [])
            .filter { $0.kind == .pdf }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private func sibling(offset: Int) -> Reference? {
        guard let index = siblings.firstIndex(where: { $0.id == reference.id }) else { return nil }
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target] : nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { showsThumbnails ? .all : .detailOnly },
            set: { showsThumbnails = $0 != .detailOnly }
        )) {
            Group {
                if isLoaded {
                    PDFThumbnails(controller: controller)
                } else {
                    Color.clear
                }
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 170, max: 260)
        } detail: {
            content
                .inspector(isPresented: $showsPanel) {
                    PDFMarkupsPanel(
                        markups: markups,
                        selection: Binding(
                            get: { controller.selectedMarkupID },
                            set: { id in
                                if let id { controller.reveal(id) } else { controller.selectedMarkupID = nil }
                            }
                        ),
                        markupToFocus: $markupToFocus,
                        service: service,
                        onSetColor: { setColor($1, on: $0) },
                        onDelete: { markupPendingDeletion = $0 }
                    )
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
                }
        }
        .frame(minWidth: 620, minHeight: 360)
        .navigationTitle(reference.displayTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .searchable(text: $findText, placement: .toolbar, prompt: "Find in PDF")
        .searchFocused($isFindFocused)
        .onSubmit(of: .search) { controller.find(findText) }
        .onChange(of: findText) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { controller.clearFind() }
        }
        .background { shortcuts }
        .task(id: reference.id) { await loadDocument() }
        .task(id: RequestedMarkup(markupID: PDFViewerRequests.shared.markupToShow[reference.id], isLoaded: isLoaded)) {
            showRequestedMarkup()
        }
        .onChange(of: MarkupItem.items(for: markups), initial: true) { _, items in
            controller.setMarkups(items)
        }
        .onAppear { connectController() }
        .onDisappear { commit() }
        .onChange(of: controller.selectedMarkupID) { commit() }
        .confirmationDialog(
            "Delete \(markupPendingDeletion?.kind.displayName ?? "")?",
            isPresented: Binding(
                get: { markupPendingDeletion != nil },
                set: { if !$0 { markupPendingDeletion = nil } }
            ),
            presenting: markupPendingDeletion
        ) { markup in
            Button("Delete", role: .destructive) { delete(markup) }
        } message: { _ in
            Text("It will be removed along with its text. The PDF isn't changed.")
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
        if isLoaded {
            PDFCanvas(controller: controller)
                .ignoresSafeArea(edges: .bottom)
        } else if let loadError {
            ContentUnavailableView("Can't Show PDF", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous PDF", systemImage: "chevron.left") {
                if let previous = sibling(offset: -1) { onNavigate(previous.id) }
            }
            .keyboardShortcut("[")
            .disabled(sibling(offset: -1) == nil)
            .help("Previous PDF (⌘[)")

            Button("Next PDF", systemImage: "chevron.right") {
                if let next = sibling(offset: 1) { onNavigate(next.id) }
            }
            .keyboardShortcut("]")
            .disabled(sibling(offset: 1) == nil)
            .help("Next PDF (⌘])")
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("Tool", selection: $controller.tool) {
                Label("Select", systemImage: "cursorarrow").tag(MarkupKind?.none)
                ForEach(MarkupKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(MarkupKind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(!isLoaded)
            .help("Select, or add a note, highlight or arrow. Hold Shift for a straight highlight. Esc stops drawing.")

            Menu {
                Picker("Colour", selection: colorBinding) {
                    ForEach(MarkupColor.allCases) { color in
                        Label { Text(color.displayName) } icon: { Image(nsImage: color.swatch) }
                            .tag(color)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label { Text("Colour") } icon: { Image(nsImage: colorBinding.wrappedValue.swatch) }
            }
            .disabled(!isLoaded)
            .help("Colour of the selected markup, and of new ones")

            Toggle(isOn: $controller.showsMarkups) {
                Label(controller.showsMarkups ? "Hide Markups" : "Show Markups",
                      systemImage: controller.showsMarkups ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .keyboardShortcut("b")
            .disabled(!isLoaded)
            .help(controller.showsMarkups ? "Hide markups to see the whole page (⌘B)" : "Show markups (⌘B)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { controller.zoomOut() }
                    .keyboardShortcut("-")
                    .help("Zoom Out (⌘−)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { controller.zoomIn() }
                    .keyboardShortcut("=")
                    .help("Zoom In (⌘=)")
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
            .disabled(!isLoaded)

            Menu("\(controller.zoomPercent)%") {
                Button("Zoom to Fit") { controller.zoomToFit() }
                Button("Actual Size") { controller.actualSize() }
            }
            .monospacedDigit()
            .fixedSize()
            .disabled(!isLoaded)
            .help("Zoom to Fit (⌘9) or Actual Size (⌘0)")
            .accessibilityLabel("Zoom \(controller.zoomPercent) percent")

            if controller.matchCount > 0 || !controller.findQuery.isEmpty {
                ControlGroup {
                    Button("Previous Match", systemImage: "chevron.backward") { controller.findPrevious() }
                        .help("Previous Match (⇧⌘G)")
                    Button("Next Match", systemImage: "chevron.forward") { controller.findNext() }
                        .help("Next Match (⌘G)")
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .disabled(controller.matchCount == 0)
            }

            Button("Export Marked-Up Copy…", systemImage: "square.and.arrow.up") { exportMarkedUpCopy() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isLoaded)
                .help("Save a copy of this PDF with its markups drawn in (⇧⌘E)")

            Button("Markups", systemImage: "sidebar.right") { showsPanel.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showsPanel ? "Hide Markups (⌥⌘I)" : "Show Markups (⌥⌘I)")
        }
    }

    /// Keyboard shortcuts with no button of their own.
    private var shortcuts: some View {
        Group {
            Button("Find") { isFindFocused = true }
                .keyboardShortcut("f")
            Button("Next Match") { controller.findNext() }
                .keyboardShortcut("g")
            Button("Previous Match") { controller.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Previous Page") { controller.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Page") { controller.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Zoom to Fit") { controller.zoomToFit() }
                .keyboardShortcut("9")
            Button("Actual Size") { controller.actualSize() }
                .keyboardShortcut("0")
        }
        .disabled(!isLoaded)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The colour menu: the selected markup's colour, or the current tool's.
    private var colorBinding: Binding<MarkupColor> {
        Binding(
            get: {
                if let id = controller.selectedMarkupID, let markup = markups.first(where: { $0.id == id }) {
                    return markup.color
                }
                return newColor(for: controller.tool ?? .highlight)
            },
            set: { color in
                if let id = controller.selectedMarkupID, let markup = markups.first(where: { $0.id == id }) {
                    setColor(color, on: markup)
                } else {
                    setNewColor(color, for: controller.tool ?? .highlight)
                }
            }
        )
    }

    private func newColor(for kind: MarkupKind) -> MarkupColor {
        switch kind {
        case .note: noteColor
        case .highlight: highlightColor
        case .arrow: arrowColor
        }
    }

    private func setNewColor(_ color: MarkupColor, for kind: MarkupKind) {
        switch kind {
        case .note: noteColor = color
        case .highlight: highlightColor = color
        case .arrow: arrowColor = color
        }
    }

    /// e.g. "F-16CJ · Page 3 of 12 · 2 of 7 found".
    private var subtitle: String {
        var parts = [reference.project?.name].compactMap { $0 }
        if isLoaded {
            parts.append(String(localized: "Page \(controller.pageIndex + 1) of \(controller.pageCount)"))
        }
        if !controller.findQuery.isEmpty {
            if controller.matchCount > 0, let index = controller.matchIndex {
                parts.append(String(localized: "\(index + 1) of \(controller.matchCount) found"))
            } else {
                parts.append(String(localized: "Not found"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func loadDocument() async {
        do {
            controller.show(try await PDFDocument.load(reference, from: assetLibrary))
            isLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func connectController() {
        controller.onRequest = { request in handle(request) }
        controller.onMove = { id, offset, bounds in move(id, by: offset, within: bounds) }
        controller.onDelete = { id in markupPendingDeletion = markups.first { $0.id == id } }
        controller.onSetColor = { id, color in
            if let markup = markups.first(where: { $0.id == id }) { setColor(color, on: markup) }
        }
        controller.onEdit = { id in
            showsPanel = true
            markupToFocus = id
        }
        controller.newMarkupColor = { kind in newColor(for: kind) }
    }

    private struct RequestedMarkup: Equatable {
        let markupID: UUID?
        let isLoaded: Bool
    }

    /// Selects the requested markup and scrolls to it, once the PDF is shown.
    private func showRequestedMarkup() {
        guard isLoaded, let id = PDFViewerRequests.shared.markupToShow[reference.id] else { return }
        PDFViewerRequests.shared.markupToShow[reference.id] = nil
        guard markups.contains(where: { $0.id == id }) else { return }
        controller.showsMarkups = true
        showsPanel = true
        controller.setMarkups(MarkupItem.items(for: markups))
        controller.reveal(id)
    }

    private func handle(_ request: MarkupRequest) {
        do {
            let markup: Markup?
            switch request {
            case .note(let page, let point, let bounds):
                markup = try service.addNote(to: reference, page: page, at: point, pageBounds: bounds,
                                             color: newColor(for: .note))
                // A note is written straight away; go back to selecting.
                controller.tool = nil
                if let markup {
                    showsPanel = true
                    markupToFocus = markup.id
                }
            case .stroke(.highlight, let page, let points, let bounds):
                markup = try service.addHighlight(to: reference, page: page, points: points, pageBounds: bounds,
                                                  color: newColor(for: .highlight))
            case .stroke(.arrow, let page, let points, let bounds):
                guard let start = points.first, let end = points.last else { return }
                markup = try service.addArrow(to: reference, page: page, from: start, to: end, pageBounds: bounds,
                                              color: newColor(for: .arrow))
            case .stroke(.note, _, _, _):
                markup = nil
            }
            if let markup {
                controller.setMarkups(MarkupItem.items(for: markups))
                controller.selectedMarkupID = markup.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(_ id: UUID, by offset: CGSize, within bounds: CGRect) {
        guard let markup = markups.first(where: { $0.id == id }) else { return }
        do {
            try service.move(markup, by: offset, within: bounds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setColor(_ color: MarkupColor, on markup: Markup) {
        setNewColor(color, for: markup.kind)
        do {
            try service.setColor(color, on: markup)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ markup: Markup) {
        if controller.selectedMarkupID == markup.id { controller.selectedMarkupID = nil }
        do {
            try service.delete(markup)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        do {
            try service.commit()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportMarkedUpCopy() {
        commit()
        Task {
            do {
                try await MarkupExporter.saveMarkedUpCopy(of: reference, from: assetLibrary)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}

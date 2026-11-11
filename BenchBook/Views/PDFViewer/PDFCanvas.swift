import PDFKit
import SwiftUI

/// Something the user drew that should become a markup.
enum MarkupRequest: Equatable {
    case note(page: Int, point: CGPoint, pageBounds: CGRect)
    case stroke(MarkupKind, page: Int, points: [CGPoint], pageBounds: CGRect)
}

/// Owns the PDF view and the state the toolbar shows: page, zoom, Find
/// matches, the drawing tool and the selected markup. The document is only
/// read, never written back.
@Observable
final class PDFViewerController: NSObject {
    static let minimumScale: CGFloat = 0.1
    static let maximumScale: CGFloat = 8

    @ObservationIgnored let pdfView = MarkupPDFView()

    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var zoomPercent = 100
    private(set) var matchCount = 0
    /// The match being shown, if any.
    private(set) var matchIndex: Int?
    @ObservationIgnored private var matches: [PDFSelection] = []
    /// The text last searched for; empty when Find is cleared.
    private(set) var findQuery = ""

    /// The kind of markup clicking or dragging draws; nil to select and move them.
    var tool: MarkupKind? {
        didSet { pdfView.window?.invalidateCursorRects(for: pdfView) }
    }
    var selectedMarkupID: UUID? {
        didSet { if oldValue != selectedMarkupID { redrawMarkups() } }
    }
    var showsMarkups = true {
        didSet {
            if !showsMarkups { tool = nil }
            redrawMarkups()
        }
    }

    // Set by the view; called when the user draws, moves or changes a markup.
    @ObservationIgnored var onRequest: (MarkupRequest) -> Void = { _ in }
    @ObservationIgnored var onMove: (UUID, CGSize, CGRect) -> Void = { _, _, _ in }
    @ObservationIgnored var onDelete: (UUID) -> Void = { _ in }
    @ObservationIgnored var onSetColor: (UUID, MarkupColor) -> Void = { _, _ in }
    @ObservationIgnored var onEdit: (UUID) -> Void = { _ in }
    /// The colour a new markup of a kind starts with.
    @ObservationIgnored var newMarkupColor: (MarkupKind) -> MarkupColor = { $0.defaultColor }

    @ObservationIgnored private var items: [MarkupItem] = []
    @ObservationIgnored private var previewAnnotation: (annotation: MarkupAnnotation, page: PDFPage)?
    /// A markup being dragged, hidden while its preview follows the mouse.
    @ObservationIgnored private var hiddenMarkupID: UUID?

    override init() {
        super.init()
        pdfView.host = self
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = Self.minimumScale
        pdfView.maxScaleFactor = Self.maximumScale
        pdfView.autoScales = true
        // Selector observers are removed automatically when the controller goes.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
    }

    func show(_ document: PDFDocument) {
        pdfView.document = document
        pdfView.autoScales = true
        pageCount = document.pageCount
        clearFind()
        pageChanged()
        scaleChanged()
        redrawMarkups()
    }

    // MARK: Markups

    var markupItems: [MarkupItem] { items }

    /// Shows these markups, replacing any shown before.
    func setMarkups(_ newItems: [MarkupItem]) {
        guard newItems != items else { return }
        items = newItems
        if let selectedMarkupID, !items.contains(where: { $0.id == selectedMarkupID }) {
            self.selectedMarkupID = nil
        }
        redrawMarkups()
    }

    /// Selects a markup and scrolls to it.
    func reveal(_ id: UUID) {
        selectedMarkupID = id
        guard let item = items.first(where: { $0.id == id }),
              let page = pdfView.document?.page(at: item.pageIndex) else { return }
        pdfView.go(to: item.drawingBounds.insetBy(dx: -40, dy: -40), on: page)
    }

    /// The topmost shown markup at `point` on a page.
    func markup(at point: CGPoint, onPage index: Int) -> MarkupItem? {
        guard showsMarkups else { return nil }
        let tolerance = 4 / max(pdfView.scaleFactor, 0.01)
        return items.last { item in
            item.pageIndex == index
                && MarkupGeometry.hits(point, kind: item.kind, rect: item.rect, points: item.points, tolerance: tolerance)
        }
    }

    /// Shows a markup while it's drawn or dragged; nil removes it.
    func setPreview(_ item: MarkupItem?, hiding id: UUID? = nil) {
        if let previewAnnotation { previewAnnotation.page.removeAnnotation(previewAnnotation.annotation) }
        previewAnnotation = nil
        if hiddenMarkupID != id {
            hiddenMarkupID = id
            redrawMarkups()
        }
        guard let item, let page = pdfView.document?.page(at: item.pageIndex) else { return }
        let annotation = MarkupAnnotation(item, selected: id != nil)
        page.addAnnotation(annotation)
        previewAnnotation = (annotation, page)
    }

    private func redrawMarkups() {
        guard let document = pdfView.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation is MarkupAnnotation
                && annotation !== previewAnnotation?.annotation {
                page.removeAnnotation(annotation)
            }
        }
        guard showsMarkups else { return }
        for item in items where item.id != hiddenMarkupID {
            document.page(at: item.pageIndex)?.addAnnotation(MarkupAnnotation(item, selected: item.id == selectedMarkupID))
        }
    }

    // MARK: Zoom

    func zoomIn() { setScale(pdfView.scaleFactor * 1.25) }
    func zoomOut() { setScale(pdfView.scaleFactor / 1.25) }

    /// Fits the page width to the window, and keeps it fitted as the window resizes.
    func zoomToFit() { pdfView.autoScales = true }

    func actualSize() { setScale(1) }

    private func setScale(_ scale: CGFloat) {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, Self.minimumScale), Self.maximumScale)
    }

    // MARK: Pages

    var canGoToPreviousPage: Bool { pageIndex > 0 }
    var canGoToNextPage: Bool { pageIndex < pageCount - 1 }

    func goToPreviousPage() { pdfView.goToPreviousPage(nil) }
    func goToNextPage() { pdfView.goToNextPage(nil) }

    func goToPage(at index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    // MARK: Find

    /// Highlights every match for `query` and shows the first one after the
    /// current page. Searching for the same text again moves to the next match.
    func find(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != findQuery || matches.isEmpty else {
            findNext()
            return
        }
        clearFind()
        guard !query.isEmpty, let document = pdfView.document else { return }
        findQuery = query
        matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = .findHighlightColor }
        matchCount = matches.count
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        let fromCurrentPage = matches.firstIndex { match in
            match.pages.first.map { document.index(for: $0) >= pageIndex } ?? false
        }
        show(match: matches.isEmpty ? nil : fromCurrentPage ?? 0)
    }

    func findNext() { show(match: Self.step(matchIndex, by: 1, count: matches.count)) }
    func findPrevious() { show(match: Self.step(matchIndex, by: -1, count: matches.count)) }

    func clearFind() {
        findQuery = ""
        matches = []
        matchCount = 0
        matchIndex = nil
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    /// The next match index, wrapping around at either end.
    nonisolated static func step(_ index: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return offset >= 0 ? 0 : count - 1 }
        return ((index + offset) % count + count) % count
    }

    private func show(match index: Int?) {
        matchIndex = index
        guard let index, matches.indices.contains(index) else { return }
        let match = matches[index]
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.go(to: match)
    }

    // MARK: Notifications

    @objc private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            pageIndex = 0
            return
        }
        pageIndex = document.index(for: page)
    }

    @objc private func scaleChanged() {
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }
}

/// The PDF view, plus drawing, selecting and moving markups with the mouse.
/// Clicks that aren't on a markup, with no tool chosen, select text as usual.
final class MarkupPDFView: PDFView {
    weak var host: PDFViewerController?

    private enum Drag {
        case stroke(MarkupKind, page: PDFPage, points: [CGPoint])
        case move(MarkupItem, page: PDFPage, start: CGPoint, offset: CGSize)
    }

    private var drag: Drag?

    override func mouseDown(with event: NSEvent) {
        guard let host, let (page, point) = pagePoint(for: event) else {
            super.mouseDown(with: event)
            return
        }
        let index = document?.index(for: page) ?? 0
        let bounds = page.bounds(for: displayBox)

        if let tool = host.tool {
            window?.makeFirstResponder(self)
            let start = MarkupGeometry.clamp(point, to: bounds)
            switch tool {
            case .note:
                host.onRequest(.note(page: index, point: start, pageBounds: bounds))
            case .highlight, .arrow:
                drag = .stroke(tool, page: page, points: [start])
            }
            return
        }

        if let item = host.markup(at: point, onPage: index) {
            window?.makeFirstResponder(self)
            host.selectedMarkupID = item.id
            if event.clickCount == 2 {
                host.onEdit(item.id)
            } else {
                drag = .move(item, page: page, start: point, offset: .zero)
            }
            return
        }

        host.selectedMarkupID = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let current = drag else {
            super.mouseDragged(with: event)
            return
        }
        switch current {
        case .stroke(let kind, let page, var points):
            let bounds = page.bounds(for: displayBox)
            let point = MarkupGeometry.clamp(convert(convert(event.locationInWindow, from: nil), to: page), to: bounds)
            // Arrows are straight; Shift draws a straight highlight.
            if kind == .arrow || event.modifierFlags.contains(.shift) {
                points = [points[0], point]
            } else {
                points.append(point)
            }
            drag = .stroke(kind, page: page, points: points)
            host.setPreview(.preview(kind, page: document?.index(for: page) ?? 0, points: points,
                                     color: host.newMarkupColor(kind)))
        case .move(let item, let page, let start, _):
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            let offset = MarkupGeometry.clampedOffset(CGSize(width: point.x - start.x, height: point.y - start.y),
                                                      moving: item.rect, within: page.bounds(for: displayBox))
            drag = .move(item, page: page, start: start, offset: offset)
            host.setPreview(item.offset(by: offset), hiding: item.id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let host, let finished = drag else {
            super.mouseUp(with: event)
            return
        }
        drag = nil
        host.setPreview(nil)
        switch finished {
        case .stroke(let kind, let page, let points):
            host.onRequest(.stroke(kind, page: document?.index(for: page) ?? 0, points: points,
                                   pageBounds: page.bounds(for: displayBox)))
        case .move(let item, let page, _, let offset):
            if offset != .zero { host.onMove(item.id, offset, page.bounds(for: displayBox)) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let host else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        switch event.keyCode {
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty:  // Delete, Forward Delete
            if let id = host.selectedMarkupID { host.onDelete(id) } else { super.keyDown(with: event) }
        case 53:  // Escape
            if host.tool != nil || host.selectedMarkupID != nil {
                host.tool = nil
                host.selectedMarkupID = nil
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let host, let (page, point) = pagePoint(for: event),
              let item = host.markup(at: point, onPage: document?.index(for: page) ?? 0) else {
            return super.menu(for: event)
        }
        host.selectedMarkupID = item.id
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(String(localized: "Edit Text")) { host.onEdit(item.id) })
        let colors = NSMenu()
        for color in MarkupColor.allCases {
            let entry = ActionMenuItem(color.displayName) { host.onSetColor(item.id, color) }
            entry.image = color.swatch
            entry.state = color == item.color ? .on : .off
            colors.addItem(entry)
        }
        let colorItem = NSMenuItem(title: String(localized: "Colour"), action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "Delete \(item.kind.displayName)…")) { host.onDelete(item.id) })
        return menu
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if host?.tool != nil { addCursorRect(visibleRect, cursor: .crosshair) }
    }

    override func mouseMoved(with event: NSEvent) {
        if host?.tool != nil {
            NSCursor.crosshair.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    /// The page under the mouse and the point on it, in page coordinates.
    private func pagePoint(for event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The scrolling pages.
struct PDFCanvas: NSViewRepresentable {
    let controller: PDFViewerController

    func makeNSView(context: Context) -> MarkupPDFView { controller.pdfView }

    func updateNSView(_ view: MarkupPDFView, context: Context) {}
}

/// Page thumbnails for the sidebar; clicking one goes to that page.
struct PDFThumbnails: NSViewRepresentable {
    let controller: PDFViewerController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = controller.pdfView
        view.thumbnailSize = CGSize(width: 110, height: 140)
        view.backgroundColor = .clear
        view.allowsMultipleSelection = false
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}

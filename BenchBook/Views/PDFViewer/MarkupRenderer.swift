import AppKit
import PDFKit

/// A markup as drawn: a snapshot of the record plus its number.
struct MarkupItem: Equatable, Identifiable {
    let id: UUID
    let pageIndex: Int
    let kind: MarkupKind
    let color: MarkupColor
    let rect: CGRect
    let points: [CGPoint]
    let text: String
    let number: Int

    init(id: UUID = UUID(), pageIndex: Int, kind: MarkupKind, color: MarkupColor, rect: CGRect,
         points: [CGPoint] = [], text: String = "", number: Int = 0) {
        self.id = id
        self.pageIndex = pageIndex
        self.kind = kind
        self.color = color
        self.rect = rect
        self.points = points
        self.text = text
        self.number = number
    }

    /// The numbered items for a PDF's markups, in page order.
    static func items(for markups: [Markup]) -> [MarkupItem] {
        markups.enumerated().map { index, markup in
            MarkupItem(id: markup.id, pageIndex: markup.pageIndex, kind: markup.kind, color: markup.color,
                       rect: markup.rect, points: markup.strokePoints, text: markup.text, number: index + 1)
        }
    }

    /// A stroke being drawn, before it's saved.
    static func preview(_ kind: MarkupKind, page: Int, points: [CGPoint], color: MarkupColor) -> MarkupItem {
        let width = kind == .arrow ? MarkupGeometry.arrowHeadLength : MarkupGeometry.highlightWidth
        return MarkupItem(pageIndex: page, kind: kind, color: color,
                          rect: MarkupGeometry.bounds(of: points, lineWidth: width), points: points)
    }

    func offset(by delta: CGSize) -> MarkupItem {
        MarkupItem(id: id, pageIndex: pageIndex, kind: kind, color: color,
                   rect: rect.offsetBy(dx: delta.width, dy: delta.height),
                   points: points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) },
                   text: text, number: number)
    }

    /// Where the number badge sits: a note's top-left corner, or a stroke's start.
    var badgeCenter: CGPoint {
        switch kind {
        case .note: CGPoint(x: rect.minX, y: rect.maxY)
        case .highlight, .arrow: points.first ?? CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// Everything drawn, including the badge and selection outline.
    var drawingBounds: CGRect {
        let radius = MarkupGeometry.badgeDiameter / 2
        let badge = CGRect(x: badgeCenter.x - radius, y: badgeCenter.y - radius,
                           width: radius * 2, height: radius * 2)
        return rect.union(badge).insetBy(dx: -6, dy: -6)
    }
}

/// Draws markups in page coordinates, for the viewer and for export.
enum MarkupRenderer {
    static func draw(_ item: MarkupItem, selected: Bool = false, showsNumber: Bool = true, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        switch item.kind {
        case .note: drawNote(item, in: context)
        case .highlight: drawHighlight(item, in: context)
        case .arrow: drawArrow(item, in: context)
        }
        if selected {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(item.rect.insetBy(dx: -4, dy: -4))
            context.setLineDash(phase: 0, lengths: [])
        }
        if showsNumber, item.number > 0 {
            drawBadge(item.number, at: item.badgeCenter, color: selected ? .controlAccentColor : item.color.nsColor,
                      in: context)
        }
    }

    private static func drawNote(_ item: MarkupItem, in context: CGContext) {
        let fill = item.color.nsColor.blended(withFraction: 0.6, of: .white) ?? item.color.nsColor
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(fill.cgColor)
        context.fill(item.rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(item.color.nsColor.cgColor)
        context.setLineWidth(1)
        context.stroke(item.rect.insetBy(dx: 0.5, dy: 0.5))

        guard !item.text.isEmpty else { return }
        let inset = MarkupGeometry.notePadding
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: item.text, attributes: MarkupGeometry.noteTextAttributes)
            .draw(with: item.rect.insetBy(dx: inset, dy: inset), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawHighlight(_ item: MarkupItem, in context: CGContext) {
        guard let first = item.points.first else { return }
        context.setBlendMode(.multiply)
        context.setStrokeColor(item.color.nsColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(MarkupGeometry.highlightWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: first)
        for point in item.points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    private static func drawArrow(_ item: MarkupItem, in context: CGContext) {
        guard let start = item.points.first, let end = item.points.last, start != end else { return }
        let color = item.color.nsColor.cgColor
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = MarkupGeometry.arrowHeadLength
        let spread: CGFloat = .pi / 7
        // Stop the line short of the tip so it doesn't poke through the head.
        let lineEnd = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)

        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(MarkupGeometry.arrowWidth)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: lineEnd)
        context.strokePath()

        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - cos(angle - spread) * head, y: end.y - sin(angle - spread) * head))
        context.addLine(to: CGPoint(x: end.x - cos(angle + spread) * head, y: end.y - sin(angle + spread) * head))
        context.closePath()
        context.fillPath()
    }

    private static func drawBadge(_ number: Int, at center: CGPoint, color: NSColor, in context: CGContext) {
        let diameter = MarkupGeometry.badgeDiameter
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: circle)

        let textColor: NSColor = color == .systemYellow || color == .systemGreen ? .black : .white
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: textColor,
        ])
        let size = label.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Shows one markup on a page of the viewer. It exists only in memory and
/// is never saved into the PDF.
final class MarkupAnnotation: PDFAnnotation {
    let item: MarkupItem
    let isMarkupSelected: Bool

    init(_ item: MarkupItem, selected: Bool) {
        self.item = item
        self.isMarkupSelected = selected
        super.init(bounds: item.drawingBounds, forType: .stamp, withProperties: nil)
        shouldPrint = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        MarkupRenderer.draw(item, selected: isMarkupSelected, in: context)
    }
}

/// Saves a separate copy of a PDF with its markups drawn into the pages.
enum MarkupExporter {
    /// Each page of `document` as it appears in the viewer (its crop box and
    /// rotation), with `markups` drawn on top. Notes show their text on the
    /// page; highlights and arrows with text keep their number, and a last
    /// page lists what each number says.
    static func markedUpData(of document: PDFDocument, markups: [MarkupItem]) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let output = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        let byPage = Dictionary(grouping: markups, by: \.pageIndex)
        var lastPageSize = CGSize.zero

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let source = page.pageRef else { continue }
            let crop = page.bounds(for: .cropBox)
            let turned = abs(page.rotation) % 180 == 90
            var mediaBox = CGRect(origin: .zero, size: turned ? CGSize(width: crop.height, height: crop.width) : crop.size)
            lastPageSize = mediaBox.size
            output.beginPage(mediaBox: &mediaBox)
            output.saveGState()
            // Maps page coordinates onto the output page, turning it as the page says.
            output.concatenate(source.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
            output.clip(to: crop)
            output.drawPDFPage(source)
            for item in byPage[index] ?? [] {
                MarkupRenderer.draw(item, showsNumber: isListed(item), in: output)
            }
            output.restoreGState()
            output.endPage()
        }
        // The list matches the PDF's pages, unless they're too small to read it on.
        let letter = CGSize(width: 612, height: 792)
        let listSize = lastPageSize.width >= letter.width && lastPageSize.height >= letter.height ? lastPageSize : letter
        drawList(markups.filter { isListed($0) }, pageSize: listSize, in: output)
        output.closePDF()
        return data as Data
    }

    /// Highlights and arrows whose text only shows in the panel.
    static func isListed(_ item: MarkupItem) -> Bool {
        item.kind != .note && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text of listed markups, e.g. "3. Page 2 · Highlight: Paint XF-1", over as many pages as it needs.
    private static func drawList(_ items: [MarkupItem], pageSize: CGSize, in output: CGContext) {
        guard !items.isEmpty else { return }
        let text = NSMutableAttributedString(string: String(localized: "Markup Notes") + "\n\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black,
        ])
        for item in items {
            let heading = String(localized: "\(item.number). Page \(item.pageIndex + 1) · \(item.kind.displayName)")
            text.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black,
            ]))
            text.append(NSAttributedString(string: item.text + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
            ]))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let margin: CGFloat = 54
        let frameRect = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var start = 0
        while start < text.length {
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            output.beginPage(mediaBox: &mediaBox)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, output)
            let visible = CTFrameGetVisibleStringRange(frame).length
            output.endPage()
            guard visible > 0 else { break }
            start += visible
        }
    }
}

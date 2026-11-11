import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import BenchBook

struct MarkupGeometryTests {
    @Test func simplifiesStrokesButKeepsTheEnds() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0)]
        #expect(MarkupGeometry.simplified(points) == [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0)])
        #expect(MarkupGeometry.simplified([CGPoint(x: 3, y: 3)]) == [CGPoint(x: 3, y: 3)])
        #expect(MarkupGeometry.simplified([]) == [])
    }

    @Test func hitsStrokesNearTheirPath() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let rect = MarkupGeometry.bounds(of: line, lineWidth: MarkupGeometry.highlightWidth)
        #expect(MarkupGeometry.hits(CGPoint(x: 50, y: 6), kind: .highlight, rect: rect, points: line, tolerance: 2))
        #expect(!MarkupGeometry.hits(CGPoint(x: 50, y: 12), kind: .highlight, rect: rect, points: line, tolerance: 2))
        #expect(MarkupGeometry.hits(CGPoint(x: 50, y: 2), kind: .arrow, rect: rect, points: line, tolerance: 2))
        #expect(!MarkupGeometry.hits(CGPoint(x: 50, y: 6), kind: .arrow, rect: rect, points: line, tolerance: 2))
        #expect(!MarkupGeometry.hits(CGPoint(x: 120, y: 0), kind: .arrow, rect: rect, points: line, tolerance: 2))
        let note = CGRect(x: 10, y: 10, width: 50, height: 30)
        #expect(MarkupGeometry.hits(CGPoint(x: 30, y: 20), kind: .note, rect: note, points: [], tolerance: 0))
    }

    @Test func movesStayOnThePage() {
        let page = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rect = CGRect(x: 150, y: 10, width: 40, height: 20)
        #expect(MarkupGeometry.clampedOffset(CGSize(width: 30, height: -30), moving: rect, within: page)
                == CGSize(width: 10, height: -10))
        #expect(MarkupGeometry.clampedOffset(CGSize(width: -5, height: 5), moving: rect, within: page)
                == CGSize(width: -5, height: 5))
    }

    @Test func pointsRoundTripThroughStorage() {
        let points = [CGPoint(x: 1.5, y: 2), CGPoint(x: 3, y: 4.25)]
        #expect(MarkupGeometry.flatten(points) == [1.5, 2, 3, 4.25])
        #expect(MarkupGeometry.points(from: [1.5, 2, 3, 4.25]) == points)
        #expect(MarkupGeometry.points(from: [1]) == [])
    }
}

@MainActor
struct MarkupServiceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: MarkupService { MarkupService(context: context) }
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func makePDF(in project: Project? = nil) throws -> Reference {
        let reference = Reference(project: project ?? Fixtures.makeProject("F-16", in: context), kind: .pdf, title: "Sheet")
        context.insert(reference)
        try context.save()
        return reference
    }

    @Test func notesStayOnThePageAndGrowWithTheirText() throws {
        let sheet = try makePDF()
        // Clicked near the bottom-right corner: the note is moved back onto the page.
        let note = try service.addNote(to: sheet, page: 2, at: CGPoint(x: 600, y: 10), pageBounds: page, color: .green)
        #expect(note.kind == .note)
        #expect(note.color == .green)
        #expect(note.pageIndex == 2)
        #expect(note.rect.maxX == page.maxX)
        #expect(note.rect.minY == page.minY)
        #expect(abs(note.width - Double(MarkupGeometry.noteWidth)) < 0.001)

        let top = note.y + note.height
        service.setText(String(repeating: "Paint the intake XF-2 flat white before fitting. ", count: 6), on: note)
        try service.commit()
        #expect(note.height > MarkupGeometry.noteMinimumHeight)
        #expect(note.y + note.height == top)
    }

    @Test func shortStrokesAreIgnored() throws {
        let sheet = try makePDF()
        #expect(try service.addHighlight(to: sheet, page: 0, points: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)],
                                         pageBounds: page) == nil)
        #expect(try service.addArrow(to: sheet, page: 0, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 10),
                                     pageBounds: page) == nil)
        #expect(sheet.markups.isEmpty)
    }

    @Test func strokesAreKeptOnThePageAndMoveTogether() throws {
        let sheet = try makePDF()
        let highlight = try #require(try service.addHighlight(
            to: sheet, page: 0, points: [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 100), CGPoint(x: 700, y: 100)],
            pageBounds: page
        ))
        #expect(highlight.kind == .highlight)
        #expect(highlight.color == .yellow)
        #expect(highlight.strokePoints.last == CGPoint(x: 612, y: 100))
        #expect(highlight.rect.contains(CGPoint(x: 120, y: 100)))

        let arrow = try #require(try service.addArrow(
            to: sheet, page: 1, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 300), pageBounds: page
        ))
        #expect(arrow.color == .red)
        #expect(arrow.strokePoints == [CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 300)])

        try service.move(arrow, by: CGSize(width: 10, height: -20), within: page)
        #expect(arrow.strokePoints == [CGPoint(x: 60, y: 30), CGPoint(x: 210, y: 280)])
        #expect(arrow.rect.contains(CGPoint(x: 60, y: 30)))

        try service.setColor(.blue, on: arrow)
        #expect(arrow.color == .blue)

        // Numbered in page order, then the order they were added.
        let note = try service.addNote(to: sheet, page: 0, at: CGPoint(x: 300, y: 400), pageBounds: page)
        #expect(sheet.sortedMarkups.map(\.id) == [highlight.id, note.id, arrow.id])

        try service.delete(note)
        #expect(sheet.sortedMarkups.map(\.id) == [highlight.id, arrow.id])
    }

    @Test func deletingThePDFDeletesItsMarkups() throws {
        let sheet = try makePDF()
        try service.addNote(to: sheet, page: 0, at: CGPoint(x: 100, y: 100), pageBounds: page)
        context.delete(sheet)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Markup>()) == 0)
    }

    @Test func copiesKeepTheirMarkups() throws {
        let f16 = Fixtures.makeProject("F-16", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let sheet = try makePDF(in: f16)
        let note = try service.addNote(to: sheet, page: 1, at: CGPoint(x: 100, y: 100), pageBounds: page, color: .pink)
        service.setText("Check part B12", on: note)
        try service.commit()

        let folder = try TemporaryFolder()
        let transfer = ReferenceTransfer(context: context, library: AssetLibrary(rootURL: folder.url))
        let copy = try #require(try transfer.transfer([sheet], to: spitfire, mode: .copy).transferred.first)
        let copied = try #require(copy.markups.first)
        #expect(copied.id != note.id)
        #expect(copied.text == "Check part B12")
        #expect(copied.pageIndex == 1)
        #expect(copied.color == .pink)
        #expect(copied.rect == note.rect)
    }

    @Test func searchFindsMarkupText() throws {
        let sheet = try makePDF()
        try service.addNote(to: sheet, page: 0, at: CGPoint(x: 100, y: 100), pageBounds: page)
        let arrow = try #require(try service.addArrow(
            to: sheet, page: 3, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), pageBounds: page
        ))
        service.setText("Ejection seat handles", on: arrow)
        try service.commit()

        let results = SearchIndex(context: context).search(SearchQuery(text: "ejection"))
        let hit = try #require(results.referenceGroups.first?.hits.first)
        #expect(hit.reference.id == sheet.id)
        #expect(hit.matches.map(\.kind) == [.markup(id: arrow.id, number: 2, kind: .arrow)])
        #expect(hit.matches.first?.kind.label == "Arrow 2")
    }
}

@MainActor
struct MarkupDisplayTests {
    /// A PDF of the given size with a black square near its bottom-left corner.
    private func makeDocument(width: CGFloat = 200, height: CGFloat = 200) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let pdf = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.black.cgColor)
        pdf.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        pdf.endPDFPage()
        pdf.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    /// RGBA pixels of a PDF page drawn into a bitmap of its size, top row first.
    private func pixels(of page: CGPDFPage) -> (width: Int, height: Int, bytes: [UInt8]) {
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width), height = Int(box.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(page)
        return (width, height, bytes)
    }

    private func rgb(_ image: (width: Int, height: Int, bytes: [UInt8]), x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        // Page coordinates start at the bottom; bitmap rows start at the top.
        let i = ((image.height - 1 - y) * image.width + x) * 4
        return (Int(image.bytes[i]), Int(image.bytes[i + 1]), Int(image.bytes[i + 2]))
    }

    @Test func exportDrawsMarkupsOverTheUnchangedPage() throws {
        let document = try makeDocument()
        let note = MarkupItem(pageIndex: 0, kind: .note, color: .blue, rect: CGRect(x: 100, y: 100, width: 80, height: 60))
        let data = try #require(MarkupExporter.markedUpData(of: document, markups: [note]))
        // The document the markups were drawn from gains no annotations.
        #expect(document.page(at: 0)?.annotations.isEmpty == true)

        let exported = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(exported.numberOfPages == 1)
        let image = pixels(of: try #require(exported.page(at: 1)))
        let square = rgb(image, x: 30, y: 30)
        #expect(square.r < 40 && square.g < 40 && square.b < 40)
        let noteFill = rgb(image, x: 140, y: 120)
        #expect(noteFill.b > noteFill.r + 40)
        let blank = rgb(image, x: 80, y: 180)
        #expect(blank.r > 240 && blank.g > 240 && blank.b > 240)
    }

    @Test func exportListsTextThatOnlyShowsInThePanel() throws {
        let document = try makeDocument()
        let highlight = MarkupItem(pageIndex: 0, kind: .highlight, color: .yellow,
                                   rect: CGRect(x: 10, y: 100, width: 100, height: 14),
                                   points: [CGPoint(x: 10, y: 107), CGPoint(x: 110, y: 107)],
                                   text: "Use XF-1 here", number: 1)
        let silentArrow = MarkupItem(pageIndex: 0, kind: .arrow, color: .red, rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                     points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)], number: 2)
        let data = try #require(MarkupExporter.markedUpData(of: document, markups: [highlight, silentArrow]))
        let exported = try #require(PDFDocument(data: data))
        #expect(exported.pageCount == 2)
        let list = try #require(exported.page(at: 1)?.string)
        #expect(list.contains("Markup Notes"))
        #expect(list.contains("Use XF-1 here"))
        #expect(list.contains("Page 1"))
    }

    @Test func exportTurnsRotatedPagesAsTheViewerDoes() throws {
        let document = try makeDocument(width: 300, height: 200)
        let page = try #require(document.page(at: 0))
        page.rotation = 90
        let data = try #require(MarkupExporter.markedUpData(of: document, markups: []))
        let exported = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let output = try #require(exported.page(at: 1))
        #expect(output.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 300))
        #expect(output.rotationAngle == 0)

        // The black square lands where PDFKit itself shows it on the turned page.
        let thumbnail = try #require(page.thumbnail(of: CGSize(width: 200, height: 300), for: .cropBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let shown = NSBitmapImageRep(cgImage: thumbnail)
        let image = pixels(of: output)
        for (x, y) in [(20, 20), (40, 40), (20, 260), (180, 20), (180, 260), (100, 150)] {
            let expectedDark = (shown.colorAt(x: x * shown.pixelsWide / 200,
                                              y: (299 - y) * shown.pixelsHigh / 300)?.brightnessComponent ?? 1) < 0.5
            #expect((rgb(image, x: x, y: y).r < 128) == expectedDark, "at \(x), \(y)")
        }
    }

    @Test func viewerShowsHidesAndHitsMarkups() throws {
        let document = try makeDocument()
        let controller = PDFViewerController()
        controller.show(document)
        let page = try #require(document.page(at: 0))
        let note = MarkupItem(pageIndex: 0, kind: .note, color: .yellow, rect: CGRect(x: 100, y: 100, width: 80, height: 40), number: 1)
        controller.setMarkups([note])
        #expect(page.annotations.filter { $0 is MarkupAnnotation }.count == 1)
        #expect(controller.markup(at: CGPoint(x: 120, y: 120), onPage: 0)?.id == note.id)
        #expect(controller.markup(at: CGPoint(x: 120, y: 120), onPage: 1) == nil)

        // While dragging, only the preview shows.
        controller.setPreview(note.offset(by: CGSize(width: 10, height: 0)), hiding: note.id)
        #expect(page.annotations.compactMap { $0 as? MarkupAnnotation }.map(\.item.rect.minX) == [110])
        controller.setPreview(nil)
        #expect(page.annotations.compactMap { $0 as? MarkupAnnotation }.map(\.item.rect.minX) == [100])

        controller.showsMarkups = false
        #expect(page.annotations.isEmpty)
        #expect(controller.markup(at: CGPoint(x: 120, y: 120), onPage: 0) == nil)
        controller.showsMarkups = true
        controller.setMarkups([])
        #expect(page.annotations.isEmpty)
    }
}

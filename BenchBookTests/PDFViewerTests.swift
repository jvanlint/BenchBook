import AppKit
import CoreText
import PDFKit
import SwiftData
import Testing
@testable import BenchBook

struct PDFFindStepTests {
    @Test func wrapsAroundAtEitherEnd() {
        #expect(PDFViewerController.step(nil, by: 1, count: 3) == 0)
        #expect(PDFViewerController.step(nil, by: -1, count: 3) == 2)
        #expect(PDFViewerController.step(1, by: 1, count: 3) == 2)
        #expect(PDFViewerController.step(2, by: 1, count: 3) == 0)
        #expect(PDFViewerController.step(0, by: -1, count: 3) == 2)
        #expect(PDFViewerController.step(0, by: 1, count: 0) == nil)
    }
}

@MainActor
struct PDFViewerTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library"))
        container = try Fixtures.makeInMemoryContainer()
    }

    /// A PDF with one line of real text on each page, so Find has something to find.
    private func writeTextPDF(_ pages: [String], to url: URL) -> URL {
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            pdf.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            )
            pdf.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    private func importPDF(_ url: URL) async throws -> Reference {
        let project = Fixtures.makeProject("F-16", in: context)
        let outcomes = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: url, originalFilename: nil, resourceURL: nil)], into: project)
        guard case .added(let reference) = try #require(outcomes.first) else { throw CaptureError.emptyText }
        return reference
    }

    @Test func loadsTheSavedCopyWithoutChangingIt() async throws {
        let reference = try await importPDF(writeTextPDF(["Step 1 decals", "Step 2 wheels"], to: folder.file("sheet.pdf")))
        let saved = library.url(forRelativePath: try #require(reference.asset).originalRelativePath)
        let before = try Data(contentsOf: saved)

        let document = try await PDFDocument.load(reference, from: library)
        #expect(document.pageCount == 2)

        let controller = PDFViewerController()
        controller.show(document)
        controller.find("decals")
        controller.clearFind()
        #expect(try Data(contentsOf: saved) == before)
    }

    @Test func reportsAMissingCopy() async throws {
        let reference = try await importPDF(writeTextPDF(["Step 1"], to: folder.file("sheet.pdf")))
        try FileManager.default.removeItem(at: library.url(forRelativePath: try #require(reference.asset).originalRelativePath))
        await #expect(throws: PDFLoadError.missingFile) { try await PDFDocument.load(reference, from: library) }
    }

    @Test func reportsAReferenceWithoutAFile() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let note = Reference(project: project, kind: .note, title: "Plan")
        context.insert(note)
        await #expect(throws: PDFLoadError.noFile) { try await PDFDocument.load(note, from: library) }
    }

    @Test func findsMatchesAcrossPagesAndStepsThroughThem() throws {
        let url = writeTextPDF(["Apply decals 12", "Wheels", "More decals here"], to: folder.file("sheet.pdf"))
        let document = try #require(PDFDocument(url: url))
        let controller = PDFViewerController()
        controller.show(document)
        #expect(controller.pageCount == 3)

        controller.find("  DECALS ")
        #expect(controller.findQuery == "DECALS")
        #expect(controller.matchCount == 2)
        #expect(controller.matchIndex == 0)

        // Searching for the same text again moves on, as Return does in Preview.
        controller.find("DECALS")
        #expect(controller.matchIndex == 1)
        controller.findNext()
        #expect(controller.matchIndex == 0)
        controller.findPrevious()
        #expect(controller.matchIndex == 1)

        controller.find("canopy")
        #expect(controller.matchCount == 0)
        #expect(controller.matchIndex == nil)
        #expect(controller.findQuery == "canopy")

        controller.clearFind()
        #expect(controller.findQuery.isEmpty)
        #expect(controller.pdfView.highlightedSelections == nil)
    }
}

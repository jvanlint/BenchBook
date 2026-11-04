import AppKit
import Foundation
import Testing
@testable import BenchBook

@MainActor
struct PasteTests {
    /// Edit → Paste reaches the app when no focused view handles it.
    @Test func appReceivesPasteCommand() {
        let paste = #selector(NSText.paste(_:))
        #expect((NSApp.delegate as AnyObject?)?.responds(to: paste) == true)
        #expect(NSApp.target(forAction: paste, to: nil, from: nil) != nil)
    }

    @Test func latestRegistrationWinsAndOnlyOwnerCanClear() {
        let router = PasteRouter()
        let first = UUID(), second = UUID()
        router.register(owner: first) { _ in }
        router.register(owner: second) { _ in }
        router.unregister(owner: first)
        #expect(router.hasDestination)
        router.unregister(owner: second)
        #expect(!router.hasDestination)
    }

    /// Clipboard contents become the same captured items as a drop would.
    @Test func clipboardContentsBecomeCapturedItems() async throws {
        let folder = try TemporaryFolder()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BenchBookTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: false)

        func read() async -> ItemProviderReader.Result {
            await reader.read(PasteRouter.providers(from: pasteboard))
        }
        func fileKind(_ result: ItemProviderReader.Result) throws -> ReferenceKind {
            guard case .file(let url, _, _) = try #require(result.items.first) else { throw CaptureError.emptyText }
            return try FileInspector.inspect(url).kind
        }

        // Browser "Copy Image": TIFF only.
        let png = try Fixtures.writePNG(to: folder.file("source.png"))
        pasteboard.clearContents()
        pasteboard.setData(NSImage(contentsOf: png)!.tiffRepresentation, forType: .tiff)
        #expect(PasteRouter.hasSupportedContent(pasteboard))
        #expect(try fileKind(await read()) == .image)

        // PNG data.
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: png), forType: .png)
        #expect(try fileKind(await read()) == .image)

        // Finder "Copy" of a file.
        let pdf = try Fixtures.writePDF(to: folder.file("manual.pdf"))
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf as NSURL])
        let fileResult = await read()
        guard case .file(let url, let name, _) = try #require(fileResult.items.first) else {
            Issue.record("Expected a file, got \(fileResult.items)")
            return
        }
        #expect(url.standardizedFileURL == pdf.standardizedFileURL)
        #expect(name == "manual.pdf")

        // A copied link.
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://youtu.be/abc123?t=30")! as NSURL])
        #expect(await read().items == [.link(url: URL(string: "https://youtu.be/abc123?t=30")!, title: nil)])

        // Copied text.
        pasteboard.clearContents()
        pasteboard.setString("Main gear bay is white.", forType: .string)
        #expect(await read().items == [.text("Main gear bay is white.", sourceURL: nil, title: nil)])

        // Something unsupported doesn't enable Paste.
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        #expect(!PasteRouter.hasSupportedContent(pasteboard))
    }
}

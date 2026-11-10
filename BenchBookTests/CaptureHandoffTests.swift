import AppKit
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BenchBook

@MainActor
struct CaptureHandoffTests {
    @Test func envelopeRoundTripsThroughInbox() throws {
        let folder = try TemporaryFolder()
        let inbox = CaptureInboxStore(inboxURL: folder.url)
        let staging = try inbox.makeStagingFolder()
        try Fixtures.writePNG(to: staging.appending(path: "photo.png"))

        let envelope = CaptureEnvelope(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), projectID: UUID(),
            tags: ["wheel well"], note: "Port side",
            items: [
                .file(name: "photo.png", originalFilename: "IMG_1.png", resourceURL: nil),
                .file(name: "../escape.png", originalFilename: nil, resourceURL: nil),
                .link(url: URL(string: "https://example.com")!, title: "Example"),
                .text("Quote", sourceURL: nil, title: nil),
            ]
        )
        #expect(inbox.pendingFolders().isEmpty)
        try inbox.commit(envelope, stagingFolder: staging)

        let pending = inbox.pendingFolders()
        #expect(pending.map(\.lastPathComponent) == [envelope.id.uuidString])
        let read = try inbox.readEnvelope(in: pending[0])
        #expect(read == envelope)

        let items = read.capturedItems(in: pending[0])
        #expect(items[1] == nil)
        guard case .file(let url, let name, _) = items[0] else {
            Issue.record("Expected a file item")
            return
        }
        #expect(name == "IMG_1.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The app side of sharing: an envelope left by the extension becomes References.
    @Test func coordinatorImportsInboxEnvelopes() async throws {
        let folder = try TemporaryFolder()
        let inbox = CaptureInboxStore(inboxURL: folder.url.appending(path: "Inbox"))
        try FileManager.default.createDirectory(at: inbox.inboxURL, withIntermediateDirectories: true)
        let library = AssetLibrary(rootURL: folder.url.appending(path: "Library"))
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16", in: container.mainContext)

        let staging = try inbox.makeStagingFolder()
        try Fixtures.writePNG(to: staging.appending(path: "shared.png"))
        try inbox.commit(CaptureEnvelope(
            id: UUID(), createdAt: .now, projectID: project.id, tags: ["Wheel Well"], note: nil,
            items: [
                .file(name: "shared.png", originalFilename: "shared.png", resourceURL: nil),
                .link(url: URL(string: "https://youtu.be/abc123?t=30")!, title: nil),
            ]
        ), stagingFolder: staging)

        let coordinator = CaptureCoordinator(context: container.mainContext, library: library, inbox: inbox)
        coordinator.processInbox()
        for _ in 0..<100 where !inbox.pendingFolders().isEmpty || project.references.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(project.references.count == 2)
        #expect(project.references.allSatisfy { $0.tags.map(\.name) == ["Wheel Well"] })
        #expect(inbox.pendingFolders().isEmpty)
        #expect(coordinator.report == nil)
    }

    @Test func readerCombinesSelectedTextWithPageLink() async throws {
        let folder = try TemporaryFolder()
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: true)
        let providers = [
            NSItemProvider(object: NSURL(string: "https://example.com/f16")!),
            NSItemProvider(object: "Main gear bay is white." as NSString),
        ]

        let result = await reader.read(providers, title: "F-16 Walkaround")

        #expect(result.items == [.text("Main gear bay is white.", sourceURL: URL(string: "https://example.com/f16"), title: "F-16 Walkaround")])
    }

    /// Highlighted text shared from a browser comes as both the content text
    /// and an attachment, often with no title.
    @Test func sharedSelectionIsKeptWithoutATitle() async throws {
        let folder = try TemporaryFolder()
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: true)

        let attached = await reader.read(
            attachments: [NSItemProvider(object: "Main gear bay is white." as NSString)],
            title: nil, contentText: "Main gear bay is white."
        )
        #expect(attached.items == [.text("Main gear bay is white.", sourceURL: nil, title: nil)])

        let contentOnly = await reader.read(attachments: [], title: nil, contentText: "Main gear bay is white.")
        #expect(contentOnly.items == [.text("Main gear bay is white.", sourceURL: nil, title: nil)])

        // Safari: a long selection as content text only, with no title or attachments.
        let long = String(repeating: "The main gear bay is white, the struts are too. ", count: 16)
        let safari = await reader.read(attachments: [], title: nil, contentText: long)
        #expect(safari.items == [.text(long, sourceURL: nil, title: nil)])

        let withPage = await reader.read(
            attachments: [
                NSItemProvider(object: NSURL(string: "https://example.com/f16")!),
                NSItemProvider(object: "Main gear bay is white." as NSString),
            ],
            title: nil, contentText: "Main gear bay is white."
        )
        #expect(withPage.items == [.text("Main gear bay is white.", sourceURL: URL(string: "https://example.com/f16"), title: nil)])
    }

    /// Sharing a page puts its title in the content text.
    @Test func sharedPageUsesContentTextAsTitle() async throws {
        let folder = try TemporaryFolder()
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: true)
        let result = await reader.read(
            attachments: [NSItemProvider(object: NSURL(string: "https://example.com/f16")!)],
            title: nil, contentText: "F-16 Walkaround"
        )
        #expect(result.items == [.link(url: URL(string: "https://example.com/f16")!, title: "F-16 Walkaround")])

        let note = await reader.read(
            attachments: [NSItemProvider(object: NSURL(string: "https://example.com/f16")!)],
            title: "F-16 Walkaround", contentText: "Gear bay is white.\nStruts are too."
        )
        #expect(note.items == [.text("Gear bay is white.\nStruts are too.", sourceURL: URL(string: "https://example.com/f16"), title: "F-16 Walkaround")])
    }

    @Test func readerReadsRichTextSelections() async throws {
        let folder = try TemporaryFolder()
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: true)
        let rich = NSAttributedString(string: "Main gear bay is white.", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            completion(rtf, nil)
            return nil
        }

        let result = await reader.read(attachments: [provider], title: nil, contentText: nil)

        #expect(result.items == [.text("Main gear bay is white.", sourceURL: nil, title: nil)])
    }

    @Test func readerTreatsLinkTextAsLinkAndCopiesFiles() async throws {
        let folder = try TemporaryFolder()
        let outputs = folder.url.appending(path: "out")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let pdf = try Fixtures.writePDF(to: folder.file("manual.pdf"))
        let unsupported = try Fixtures.writeText("x", to: folder.file("notes.docx"))
        let reader = ItemProviderReader(fileDirectory: outputs, copiesFileURLs: true)

        let result = await reader.read([
            NSItemProvider(object: " https://example.com/page " as NSString),
            NSItemProvider(contentsOf: pdf)!,
            NSItemProvider(contentsOf: unsupported)!,
        ])

        #expect(result.items.contains(.link(url: URL(string: "https://example.com/page")!, title: nil)))
        #expect(result.skipped == ["notes.docx"])
        let file = result.items.compactMap { item -> (URL, String?)? in
            if case .file(let url, let name, _) = item { return (url, name) }
            return nil
        }.first
        #expect(file?.1 == "manual.pdf")
        #expect(file?.0.deletingLastPathComponent().standardizedFileURL == outputs.standardizedFileURL)
    }
}

/// Opening a library saved by the first release keeps its Projects.
@MainActor
struct MigrationTests {
    @Test func migratesVersion1LibraryToVersion2() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")

        do {
            let v1Schema = Schema(versionedSchema: BenchBookSchemaV1.self)
            let v1 = try ModelContainer(for: v1Schema, configurations: ModelConfiguration(schema: v1Schema, url: storeURL))
            v1.mainContext.insert(BenchBookSchemaV1.Project(name: "Tamiya F-16CJ", manufacturer: "Tamiya", scale: "1:48"))
            try v1.mainContext.save()
        }

        let current = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let projects = try current.mainContext.fetch(FetchDescriptor<Project>())
        #expect(projects.map(\.name) == ["Tamiya F-16CJ"])
        #expect(projects.first?.scale == "1:48")
        #expect(projects.first?.references.isEmpty == true)
    }
}

/// Browsers sometimes hand over an error page in place of a dragged image.
@MainActor
struct BrowserImageDragTests {
    private func provider(jpegFile: URL, tiff: Data?, webURL: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "220919-N-WU964-2126.JPG"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            completion(jpegFile, false, nil)
            return nil
        }
        if let tiff {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in
                completion(tiff, nil)
                return nil
            }
        }
        provider.registerObject(webURL as NSURL, visibility: .all)
        return provider
    }

    @Test func realImageIsKeptWithItsAddress() async throws {
        let folder = try TemporaryFolder()
        let jpeg = try Fixtures.writeJPEG(to: folder.file("photo.jpg"))
        let web = URL(string: "https://media.example.mil/photo.JPG")!
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: false)

        let result = await reader.read([provider(jpegFile: jpeg, tiff: nil, webURL: web)])

        guard case .file(_, let name, let resource) = try #require(result.items.first) else {
            Issue.record("Expected a file, got \(result.items)")
            return
        }
        #expect(name == "220919-N-WU964-2126.JPG")
        #expect(resource == web)
    }

    @Test func errorPageFallsBackToOnScreenImage() async throws {
        let folder = try TemporaryFolder()
        let html = try Fixtures.writeText("<HTML><HEAD><TITLE>Access Denied</TITLE></HEAD></HTML>", to: folder.file("denied.jpg"))
        let png = try Fixtures.writePNG(to: folder.file("screen.png"))
        let tiff = try #require(NSImage(contentsOf: png)?.tiffRepresentation)
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: false)

        let result = await reader.read([provider(jpegFile: html, tiff: tiff, webURL: URL(string: "https://media.example.mil/photo.JPG")!)])

        guard case .file(let url, let name, _) = try #require(result.items.first) else {
            Issue.record("Expected a file, got \(result.items)")
            return
        }
        #expect(ItemProviderReader.isReadableImage(url))
        #expect(name == "220919-N-WU964-2126.png")
    }

    @Test func errorPageWithoutPixelsBecomesALink() async throws {
        let folder = try TemporaryFolder()
        let html = try Fixtures.writeText("<HTML>Access Denied</HTML>", to: folder.file("denied.jpg"))
        let web = URL(string: "https://media.example.mil/photo.JPG")!
        let reader = ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: false)

        let result = await reader.read([provider(jpegFile: html, tiff: nil, webURL: web)])

        #expect(result.items == [.link(url: web, title: "220919-N-WU964-2126.JPG")])
        #expect(result.skipped.isEmpty)
    }
}

/// Drops are read from the drag pasteboard, as Safari puts them there.
@MainActor
struct DragPasteboardTests {
    @Test func safariStyleImageDragBecomesAnImage() async throws {
        let folder = try TemporaryFolder()
        let png = try Fixtures.writePNG(to: folder.file("screen.png"))
        let tiff = try #require(NSImage(contentsOf: png)?.tiffRepresentation)
        let web = URL(string: "https://media.example.mil/photo.JPG")!

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BenchBookTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        item.setString(web.absoluteString, forType: .URL)
        item.setString("https://media.example.mil/photo.JPG", forType: .string)
        pasteboard.writeObjects([item])

        // SwiftUI's own providers are empty here, as when they fail.
        let providers = CaptureDrop.providers(fallback: [], pasteboard: pasteboard)
        let result = await ItemProviderReader(fileDirectory: folder.url, copiesFileURLs: false).read(providers)

        guard case .file(let url, _, let resource) = try #require(result.items.first) else {
            Issue.record("Expected an image, got \(result.items)")
            return
        }
        #expect(ItemProviderReader.isReadableImage(url))
        #expect(resource == web)
        #expect(result.items.count == 1)
        #expect(result.skipped.isEmpty)
    }
}

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

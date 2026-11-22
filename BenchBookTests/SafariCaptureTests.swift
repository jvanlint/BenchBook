import Foundation
import SwiftData
import Testing
@testable import BenchBook

/// The Safari extension: checking its messages, handing captures to the
/// inbox, and BenchBook writing results back.
@MainActor
struct SafariCaptureTests {
    // MARK: Checking messages

    @Test func refusesMalformedMessages() {
        let bad: [Any?] = [
            nil,
            "save",
            ["action": "launch"],
            ["action": "chunk", "upload": UUID().uuidString, "data": "not base64!"],
            ["action": "chunk", "upload": "not-a-uuid", "data": "AAAA"],
            ["action": "save", "item": ["kind": "page", "url": "javascript:alert(1)"]],
            ["action": "save", "item": ["kind": "page", "url": "file:///etc/passwd"]],
            ["action": "save", "item": ["kind": "file", "filename": "a.png"]],
            ["action": "save", "item": ["kind": "text", "text": "   "]],
            ["action": "save", "item": ["kind": "page", "url": "https://example.com"], "projectID": "nope"],
            ["action": "save", "item": ["kind": "page", "url": "https://example.com"], "tags": [1, 2]],
            ["action": "amend", "referenceIDs": [], "projectID": UUID().uuidString],
        ]
        for message in bad {
            #expect(throws: (any Error).self, "\(String(describing: message))") { try SafariRequest(message: message) }
        }
    }

    @Test func readsSaveMessages() throws {
        let project = UUID()
        let upload = UUID()
        let request = try SafariRequest(message: [
            "action": "save",
            "projectID": project.uuidString,
            "upload": upload.uuidString,
            "tags": [" Wheel Well ", "", "Cockpit"],
            "note": "  Port side  ",
            "item": [
                "kind": "file", "filename": "../../gear bay.jpg",
                "url": "https://cdn.example.com/gear.jpg", "pageURL": "https://example.com/f16",
            ],
        ])
        #expect(request == .save(SafariSave(
            item: .file(upload: upload, filename: "gear bay.jpg",
                        resourceURL: URL(string: "https://cdn.example.com/gear.jpg"), pageURL: URL(string: "https://example.com/f16")),
            projectID: project, tags: ["Wheel Well", "Cockpit"], note: "Port side"
        )))

        // A data: image keeps its file but not its address.
        let inline = try SafariRequest(message: [
            "action": "save", "upload": upload.uuidString,
            "item": ["kind": "file", "filename": "Image.png", "url": "data:image/png;base64,AAAA"],
        ])
        #expect(inline == .save(SafariSave(item: .file(upload: upload, filename: "Image.png", resourceURL: nil, pageURL: nil))))
    }

    @Test func filenamesAreMadeSafe() {
        #expect(SafariSave.safeFilename("../../etc/passwd", fallback: nil) == "passwd")
        #expect(SafariSave.safeFilename("..\\secret.png", fallback: nil) == "secret.png")
        #expect(SafariSave.safeFilename(".hidden.png", fallback: nil) == "hidden.png")
        #expect(SafariSave.safeFilename("bad\u{0}name.jpg", fallback: nil) == "badname.jpg")
        #expect(SafariSave.safeFilename(nil, fallback: URL(string: "https://example.com/a/photo.webp")) == "photo.webp")
        #expect(SafariSave.safeFilename("", fallback: nil) == "Download")
        #expect(SafariSave.safeFilename(String(repeating: "a", count: 300), fallback: nil).count == 200)
    }

    // MARK: Handing captures to the inbox

    private struct Setup {
        let folder: TemporaryFolder
        let inbox: CaptureInboxStore
        let results: CaptureResultStore
        let directory: ProjectDirectory
        let project = ProjectSummary(id: UUID(), name: "F-16CJ", detail: "")

        init() throws {
            folder = try TemporaryFolder()
            inbox = CaptureInboxStore(inboxURL: folder.url.appending(path: "Inbox"))
            try FileManager.default.createDirectory(at: inbox.inboxURL, withIntermediateDirectories: true)
            results = CaptureResultStore(resultsURL: folder.url.appending(path: "Results"))
            let defaults = UserDefaults(suiteName: "BenchBookTests-\(UUID().uuidString)")!
            directory = ProjectDirectory(defaults: defaults)
            directory.publish([project])
        }

        func service(timeout: Duration = .milliseconds(200)) -> SafariCaptureService {
            SafariCaptureService(inbox: inbox, results: results, directory: directory, resultTimeout: timeout)
        }
    }

    @Test func uploadsAFileInChunksAndHandsItOver() async throws {
        let setup = try Setup()
        let service = setup.service()
        let begin = await service.respond(to: ["action": "begin"])
        let upload = try #require(begin["upload"] as? String)

        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        for part in [bytes.prefix(100), bytes.dropFirst(100)] {
            let reply = await service.respond(to: ["action": "chunk", "upload": upload, "data": Data(part).base64EncodedString()])
            #expect(reply["ok"] as? Bool == true)
        }
        let reply = await service.respond(to: [
            "action": "save", "upload": upload, "tags": ["Gear"],
            "item": ["kind": "file", "filename": "gear.jpg", "url": "https://cdn.example.com/gear.jpg", "pageURL": "https://example.com/f16"],
        ])
        // No result arrived in time, so Safari says it was sent.
        #expect(reply["status"] as? String == "sent")

        let pending = setup.inbox.pendingFolders()
        #expect(pending.map(\.lastPathComponent) == [upload])
        let envelope = try setup.inbox.readEnvelope(in: pending[0])
        #expect(envelope.source == .safari)
        #expect(envelope.projectID == setup.project.id)
        #expect(envelope.pageURL == URL(string: "https://example.com/f16"))
        #expect(envelope.tags == ["Gear"])
        #expect(envelope.items == [.file(name: "gear.jpg", originalFilename: "gear.jpg", resourceURL: URL(string: "https://cdn.example.com/gear.jpg"))])
        #expect(try Data(contentsOf: pending[0].appending(path: "gear.jpg")) == bytes)
        #expect(setup.directory.activeProjectID == setup.project.id)
    }

    @Test func aDownloadCantReplaceTheEnvelope() async throws {
        let setup = try Setup()
        let service = setup.service()
        let upload = try #require(await service.respond(to: ["action": "begin"])["upload"] as? String)
        _ = await service.respond(to: ["action": "chunk", "upload": upload, "data": Data("x".utf8).base64EncodedString()])
        _ = await service.respond(to: ["action": "save", "upload": upload, "item": ["kind": "file", "filename": "envelope.json"]])

        let folder = try #require(setup.inbox.pendingFolders().first)
        let envelope = try setup.inbox.readEnvelope(in: folder)
        #expect(envelope.items == [.file(name: "Download", originalFilename: "envelope.json", resourceURL: nil)])
    }

    @Test func repliesWithBenchBooksResult() async throws {
        let setup = try Setup()
        let service = setup.service(timeout: .seconds(5))
        let results = setup.results
        let inbox = setup.inbox
        let referenceID = UUID()

        // Stands in for BenchBook: answers the envelope when it arrives.
        let app = Task.detached {
            for _ in 0..<100 {
                if let folder = inbox.pendingFolders().first, let envelope = try? inbox.readEnvelope(in: folder) {
                    try? results.write(CaptureResult(envelopeID: envelope.id, status: .saved, projectName: "F-16CJ",
                                                     referenceIDs: [referenceID]))
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let reply = await service.respond(to: ["action": "save", "item": ["kind": "page", "url": "https://example.com/f16", "title": "F-16"]])
        await app.value

        #expect(reply["status"] as? String == "saved")
        #expect(reply["projectName"] as? String == "F-16CJ")
        #expect(reply["referenceIDs"] as? [String] == [referenceID.uuidString])
        // The result is collected once.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: results.resultsURL.path))?.isEmpty == true)
    }

    @Test func explainsProblems() async throws {
        let setup = try Setup()
        let service = setup.service()

        let missing = await service.respond(to: ["action": "chunk", "upload": UUID().uuidString, "data": "AAAA"])
        #expect(missing["ok"] as? Bool == false)
        #expect(missing["error"] as? String == SafariRequestError.uploadMissing.errorDescription)

        let empty = try #require(await service.respond(to: ["action": "begin"])["upload"] as? String)
        let emptySave = await service.respond(to: ["action": "save", "upload": empty, "item": ["kind": "file", "filename": "a.png"]])
        #expect(emptySave["error"] as? String == SafariRequestError.uploadMissing.errorDescription)

        setup.directory.publish([])
        let noProjects = await service.respond(to: ["action": "save", "item": ["kind": "page", "url": "https://example.com"]])
        #expect(noProjects["error"] as? String == SafariRequestError.noProjects.errorDescription)
        #expect(setup.inbox.pendingFolders().isEmpty)
    }

    @Test func stateListsProjectsAndTags() async throws {
        let setup = try Setup()
        setup.directory.publishTags(["Cockpit", "Wheel Well"])
        let reply = await setup.service().respond(to: ["action": "state"])
        let projects = try #require(reply["projects"] as? [[String: String]])
        #expect(projects.map { $0["name"] } == ["F-16CJ"])
        #expect(reply["activeProjectID"] as? String == setup.project.id.uuidString)
        #expect(reply["tags"] as? [String] == ["Cockpit", "Wheel Well"])
    }

    @Test func versionOneEnvelopesStillRead() throws {
        let json = """
        {"version":1,"id":"\(UUID().uuidString)","createdAt":"2026-11-01T10:00:00Z","projectID":"\(UUID().uuidString)",
         "tags":[],"items":[{"link":{"url":"https://example.com"}}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CaptureEnvelope.self, from: Data(json.utf8))
        #expect(envelope.source == nil)
        #expect(envelope.amends == nil)
        #expect(envelope.items == [.link(url: URL(string: "https://example.com")!, title: nil)])
    }

    // MARK: BenchBook's side

    private func importEnvelope(_ envelope: CaptureEnvelope, files: [String: (URL) throws -> Void] = [:],
                                setup: Setup, coordinator: CaptureCoordinator) async throws -> CaptureResult? {
        let staging = try setup.inbox.makeStagingFolder()
        for (name, write) in files { try write(staging.appending(path: name)) }
        try setup.inbox.commit(envelope, stagingFolder: staging)
        coordinator.processInbox()
        for _ in 0..<100 {
            if let result = setup.results.take(envelope.id) { return result }
            try await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    @Test func benchBookReportsSavesDuplicatesAndChanges() async throws {
        let setup = try Setup()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let f16 = Fixtures.makeProject("F-16CJ", in: context)
        let spitfire = Fixtures.makeProject("Spitfire", in: context)
        let library = AssetLibrary(rootURL: setup.folder.url.appending(path: "Library"))
        let coordinator = CaptureCoordinator(context: context, library: library, inbox: setup.inbox, results: setup.results)
        let page = URL(string: "https://example.com/f16")!

        func imageEnvelope() -> CaptureEnvelope {
            CaptureEnvelope(id: UUID(), createdAt: .now, projectID: f16.id, tags: ["Gear"], note: nil,
                            items: [.file(name: "gear.png", originalFilename: "gear.png", resourceURL: URL(string: "https://cdn.example.com/gear.png"))],
                            source: .safari, pageURL: page)
        }
        let png: [String: (URL) throws -> Void] = ["gear.png": { try Fixtures.writePNG(to: $0) }]

        let saved = try #require(try await importEnvelope(imageEnvelope(), files: png, setup: setup, coordinator: coordinator))
        #expect(saved.status == .saved)
        #expect(saved.projectName == "F-16CJ")
        let reference = try #require(f16.references.first)
        #expect(saved.referenceIDs == [reference.id])
        #expect(reference.sourcePageURL == page)
        #expect(reference.originalResourceURL == URL(string: "https://cdn.example.com/gear.png"))

        // The same image again: Safari is told, and BenchBook shows no alert.
        let again = try #require(try await importEnvelope(imageEnvelope(), files: png, setup: setup, coordinator: coordinator))
        #expect(again.status == .duplicate)
        #expect(coordinator.report == nil)

        // Change…: move it to the Spitfire, adding a tag and a note.
        let change = CaptureEnvelope(id: UUID(), createdAt: .now, projectID: spitfire.id, tags: ["Undercarriage"], note: "Compare with the Mk IX",
                                     items: [], source: .safari, amends: [reference.id])
        let changed = try #require(try await importEnvelope(change, setup: setup, coordinator: coordinator))
        #expect(changed.status == .saved)
        #expect(changed.projectName == "Spitfire")
        #expect(reference.project?.id == spitfire.id)
        #expect(Set(reference.tags.map(\.name)) == ["Gear", "Undercarriage"])
        #expect(reference.note == "Compare with the Mk IX")

        // Change… a second copy to the Spitfire, which already has the image: it stays put.
        let copy = try #require(try await importEnvelope(imageEnvelope(), files: png, setup: setup, coordinator: coordinator))
        #expect(copy.status == .saved)
        let back = CaptureEnvelope(id: UUID(), createdAt: .now, projectID: spitfire.id, tags: ["Ignored"], note: nil,
                                   items: [], source: .safari, amends: copy.referenceIDs)
        let refused = try #require(try await importEnvelope(back, setup: setup, coordinator: coordinator))
        #expect(refused.status == .duplicate)
        let stayed = try #require(f16.references.first { $0.id == copy.referenceIDs.first })
        #expect(!stayed.tags.map(\.name).contains("Ignored"))

        // A project that has since been deleted.
        let gone = CaptureEnvelope(id: UUID(), createdAt: .now, projectID: UUID(), tags: [], note: nil,
                                   items: [.link(url: page, title: nil)], source: .safari)
        let failed = try #require(try await importEnvelope(gone, setup: setup, coordinator: coordinator))
        #expect(failed.status == .failed)
        #expect(failed.message == CaptureError.projectNotFound.errorDescription)
    }

    @Test func shareMenuCapturesWriteNoResult() async throws {
        let setup = try Setup()
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16CJ", in: container.mainContext)
        let library = AssetLibrary(rootURL: setup.folder.url.appending(path: "Library"))
        let coordinator = CaptureCoordinator(context: container.mainContext, library: library, inbox: setup.inbox, results: setup.results)
        let envelope = CaptureEnvelope(id: UUID(), createdAt: .now, projectID: project.id, tags: [], note: nil,
                                       items: [.link(url: URL(string: "https://example.com")!, title: nil)], source: .shareMenu)
        #expect(try await importEnvelope(envelope, setup: setup, coordinator: coordinator) == nil)
        #expect(project.references.count == 1)
    }

    // MARK: Duplicate links

    @Test func aProjectHoldsEachLinkOnce() async throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16CJ", in: container.mainContext)
        let other = Fixtures.makeProject("Spitfire", in: container.mainContext)
        let importer = ReferenceImporter(context: container.mainContext, library: AssetLibrary(rootURL: folder.url))
        let link = CapturedItem.link(url: URL(string: "https://example.com/f16")!, title: nil)

        let first = await importer.importItems([link], into: project)
        let second = await importer.importItems([link], into: project)
        let elsewhere = await importer.importItems([link], into: other)
        let video = await importer.importItems([.link(url: URL(string: "https://youtu.be/abc123?t=30")!, title: nil)], into: project)

        guard case .added = first.first, case .duplicate = second.first, case .added = elsewhere.first, case .added = video.first else {
            Issue.record("Expected added, duplicate, added, added; got \(first), \(second), \(elsewhere), \(video)")
            return
        }
        #expect(project.references.count == 2)
    }
}

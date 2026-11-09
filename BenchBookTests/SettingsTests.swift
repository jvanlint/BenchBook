import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct SettingsTests {
    @Test func fetchingIsOnUnlessTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "BenchBookTests-\(UUID().uuidString)"))
        #expect(AppSettings.fetchesLinkDetails(in: defaults))
        defaults.set(false, forKey: AppSettings.fetchesLinkDetailsKey)
        #expect(!AppSettings.fetchesLinkDetails(in: defaults))
    }

    @Test func viewerAndProjectDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "BenchBookTests-\(UUID().uuidString)"))
        #expect(!AppSettings.opensImagesAtActualSize(in: defaults))
        #expect(AppSettings.showsNoteBoxes(in: defaults))
        #expect(AppSettings.newProjectStatus(in: defaults) == .researching)

        defaults.set(true, forKey: AppSettings.opensImagesAtActualSizeKey)
        defaults.set(false, forKey: AppSettings.showsNoteBoxesKey)
        defaults.set(ProjectStatus.inProgress.rawValue, forKey: AppSettings.newProjectStatusKey)
        #expect(AppSettings.opensImagesAtActualSize(in: defaults))
        #expect(!AppSettings.showsNoteBoxes(in: defaults))
        #expect(AppSettings.newProjectStatus(in: defaults) == .inProgress)

        // An unknown value, e.g. from a newer version, falls back.
        defaults.set("archived", forKey: AppSettings.newProjectStatusKey)
        #expect(AppSettings.newProjectStatus(in: defaults) == .researching)
    }

    /// With automatic fetching off, saving a link makes no request, but
    /// Refresh still fetches.
    @Test func turnedOffFetchesOnlyWhenAsked() async throws {
        let folder = try TemporaryFolder()
        let library = AssetLibrary(rootURL: folder.url)
        let container = try Fixtures.makeInMemoryContainer()
        let web = StubWeb()
        web.add("https://example.com/page", contentType: "text/html",
                Data(#"<title>Intakes</title><meta property="og:site_name" content="Example">"#.utf8))
        let service = LinkInfoService(context: container.mainContext, library: library, pageFetcher: web.pageFetcher)
        service.fetchesAutomatically = { false }

        let project = Fixtures.makeProject("F-16", in: container.mainContext)
        let page = Reference(project: project, kind: .webpage, sourcePageURL: URL(string: "https://example.com/page")!)
        container.mainContext.insert(page)
        try container.mainContext.save()

        service.fetch([page])
        service.fetchMissing()
        try await Task.sleep(for: .milliseconds(200))
        #expect(web.requested.isEmpty)
        #expect(page.linkPreviewFetchedAt == nil)

        await service.refresh(page)
        #expect(page.linkSiteName == "Example")
        #expect(!web.requested.isEmpty)
    }

    @Test func cleanupCountsAndUsageMeasures() async throws {
        let folder = try TemporaryFolder()
        let library = AssetLibrary(rootURL: folder.url)
        let container = try Fixtures.makeInMemoryContainer()
        let references = ReferenceService(context: container.mainContext, library: library)
        #expect(try references.reconcileLibrary() == 0)

        try FileManager.default.createDirectory(at: library.originalsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: library.originalsURL.appending(path: "\(UUID().uuidString).png"))
        try Data(count: 3000).write(to: library.postersURL.appending(path: "\(UUID().uuidString).jpg"))

        let usage = LibraryUsage.measure(library)
        #expect(usage.originals >= 5000)
        #expect(usage.posters >= 3000)
        #expect(usage.thumbnails == 0)
        #expect(usage.total == usage.originals + usage.posters)

        #expect(try references.reconcileLibrary() == 2)
        #expect(LibraryUsage.measure(library).total == 0)
    }

    @Test func clearingThumbnailsKeepsOriginals() async throws {
        let folder = try TemporaryFolder()
        let library = AssetLibrary(rootURL: folder.url)
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16", in: container.mainContext)
        let image = try Fixtures.writePNG(to: folder.file("a.png"), width: 40, height: 30)
        let outcomes = await ReferenceImporter(context: container.mainContext, library: library)
            .importItems([.file(url: image, originalFilename: "a.png", resourceURL: nil)], into: project)
        guard case .added(let reference) = try #require(outcomes.first), let asset = reference.asset else {
            Issue.record("Import failed: \(outcomes)")
            return
        }
        let store = ThumbnailStore(library: library)
        #expect(await store.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath) != nil)
        #expect(FileManager.default.fileExists(atPath: library.thumbnailURL(assetID: asset.id).path))

        store.clearThumbnails()
        #expect(!FileManager.default.fileExists(atPath: library.thumbnailURL(assetID: asset.id).path))
        #expect(FileManager.default.fileExists(atPath: library.url(forRelativePath: asset.originalRelativePath).path))
        // Made again when next shown.
        #expect(await store.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath) != nil)
    }
}

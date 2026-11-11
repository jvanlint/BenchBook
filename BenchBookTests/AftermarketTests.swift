import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct AftermarketDraftTests {
    @Test func readsProductPages() {
        var draft = AftermarketDraft()
        #expect(draft.hasValidURL)  // optional
        #expect(draft.parsedURL == nil)

        draft.productURL = "  hannants.co.uk/product/GAL48012 "
        #expect(draft.parsedURL == URL(string: "https://hannants.co.uk/product/GAL48012"))
        draft.productURL = "http://example.com"
        #expect(draft.parsedURL == URL(string: "http://example.com"))
        draft.productURL = "decals for the F-16"
        #expect(!draft.hasValidURL)
        draft.productURL = "ftp://example.com/file"
        #expect(!draft.hasValidURL)
    }

    @Test func newPartsStartWithTheProjectScale() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16", in: container.mainContext)
        project.scale = "1:48"
        #expect(AftermarketDraft(project: project).scaleCompatibility == "1:48")
        #expect(AftermarketDraft(project: project).status == .considering)
    }
}

@MainActor
struct AftermarketServiceTests {
    let container: ModelContainer
    let folder: TemporaryFolder
    var context: ModelContext { container.mainContext }
    var library: AssetLibrary { AssetLibrary(rootURL: folder.url) }
    var service: AftermarketService { AftermarketService(context: context, library: library) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
        folder = try TemporaryFolder()
    }

    private func draft(_ name: String, by manufacturer: String = "", type: AftermarketType,
                       status: AftermarketStatus, fits: String = "") -> AftermarketDraft {
        var draft = AftermarketDraft()
        draft.productName = name
        draft.manufacturer = manufacturer
        draft.type = type
        draft.status = status
        draft.scaleCompatibility = fits
        return draft
    }

    private func fileCount(_ subfolder: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.url.appending(path: subfolder).path).count) ?? 0
    }

    /// The acceptance examples from the requirements.
    @Test func recordsDecalsAndThreeDPrintedParts() throws {
        let project = Fixtures.makeProject("F-16C", in: context)
        let decals = try service.create(in: project, from: draft(
            "  50th Anniversary 2015 ", by: "Galaxy Models", type: .decals, status: .using, fits: "1:48"
        ))
        try service.create(in: project, from: draft("FOD cover", type: .printed3D, status: .considering))

        #expect(decals.displayName == "Galaxy Models 50th Anniversary 2015")
        #expect(decals.type == .decals)
        #expect(decals.typeName == "Decals")
        #expect(decals.scaleCompatibility == "1:48")
        #expect(decals.status == .using)
        // Considering comes before Using.
        #expect(project.sortedAftermarketItems.map(\.productName) == ["FOD cover", "50th Anniversary 2015"])
        #expect(project.sortedAftermarketItems.first?.typeName == "3D printed")
        #expect(!context.hasChanges)
    }

    @Test func validatesAndUpdates() throws {
        let project = Fixtures.makeProject("F-16C", in: context)
        #expect(throws: AftermarketError.blankName) {
            try service.create(in: project, from: draft("  ", type: .resin, status: .ordered))
        }
        var bad = draft("Cockpit", type: .resin, status: .ordered)
        bad.productURL = "not a link"
        #expect(throws: AftermarketError.invalidURL) { try service.create(in: project, from: bad) }
        #expect(project.aftermarketItems.isEmpty)

        let item = try service.create(in: project, from: draft("Cockpit", by: "Aires", type: .resin, status: .ordered))
        var edited = AftermarketDraft(item: item)
        edited.productNumber = "4520"
        edited.productURL = "aires.cz/4520"
        edited.status = .inStash
        try service.update(item, from: edited)
        #expect(item.productNumber == "4520")
        #expect(item.secondaryLine == "Aires · 4520")
        #expect(item.productURL == URL(string: "https://aires.cz/4520"))
        #expect(item.status == .inStash)

        try service.setStatus(.used, for: [item])
        #expect(item.statusRaw == "used")
    }

    @Test func picturesAreStoredReplacedAndCleanedUp() async throws {
        let project = Fixtures.makeProject("F-16C", in: context)
        let item = try service.create(in: project, from: draft("Seat", type: .resin, status: .inStash))

        try await service.setImage(from: Fixtures.writePNG(to: folder.file("seat.png"), width: 40, height: 30), on: item)
        let first = try #require(item.imageAsset)
        #expect(first.pixelWidth == 40)
        #expect(fileCount("Originals") == 1)

        // Replacing removes the old file.
        try await service.setImage(from: Fixtures.writeJPEG(to: folder.file("seat.jpg")), on: item)
        #expect(item.imageAsset?.id != first.id)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 1)
        #expect(fileCount("Originals") == 1)

        // Cleanup at launch keeps pictures that are in use...
        try ReferenceService(context: context, library: library).reconcileLibrary()
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 1)
        #expect(fileCount("Originals") == 1)

        // ...and deleting the part removes its picture.
        try service.delete([item])
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
        #expect(fileCount("Originals") == 0)
    }

    @Test func removesPicturesAndRejectsOtherFiles() async throws {
        let project = Fixtures.makeProject("F-16C", in: context)
        let item = try service.create(in: project, from: draft("Masks", type: .masks, status: .ordered))

        let pdf = try Fixtures.writePDF(to: folder.file("instructions.pdf"))
        await #expect(throws: AftermarketError.notAnImage("instructions.pdf")) {
            try await service.setImage(from: pdf, on: item)
        }
        #expect(item.imageAsset == nil)

        try await service.setImage(from: Fixtures.writePNG(to: folder.file("masks.png")), on: item)
        try service.removeImage(from: item)
        #expect(item.imageAsset == nil)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
        #expect(fileCount("Originals") == 0)
    }

    @Test func downloadsTheProductPagePicture() async throws {
        let web = StubWeb()
        web.add("https://shop.example.com/decals.jpg", try Data(contentsOf: Fixtures.writePNG(to: folder.file("d.png"), width: 600, height: 400)))
        web.add("https://shop.example.com/apple-touch-icon.png", try Data(contentsOf: Fixtures.writePNG(to: folder.file("i.png"), width: 180, height: 180)))
        web.add("https://shop.example.com/galaxy", contentType: "text/html", Data(#"<meta property="og:image" content="/decals.jpg">"#.utf8))
        web.add("https://shop.example.com/", contentType: "text/html", Data("<title>Only an icon</title>".utf8))

        let file = try await AftermarketService.downloadPageImage(
            from: URL(string: "https://shop.example.com/galaxy")!, into: folder.file("download"), fetcher: web.pageFetcher
        )
        #expect(ItemProviderReader.isReadableImage(file))

        // A site icon isn't a picture of the product.
        await #expect(throws: AftermarketError.noPageImage) {
            try await AftermarketService.downloadPageImage(
                from: URL(string: "https://shop.example.com/other")!, into: folder.file("download2"), fetcher: web.pageFetcher
            )
        }
    }

    @Test func searchFindsParts() throws {
        let project = Fixtures.makeProject("F-16C", in: context)
        try service.create(in: project, from: draft("50th Anniversary 2015", by: "Galaxy Models", type: .decals, status: .using))
        try service.create(in: project, from: draft("FOD cover", type: .printed3D, status: .considering))

        let index = SearchIndex(context: context)
        #expect(index.search(SearchQuery(text: "galaxy decals")).aftermarketItems.map(\.productName) == ["50th Anniversary 2015"])
        #expect(index.search(SearchQuery(text: "3d printed")).aftermarketItems.map(\.productName) == ["FOD cover"])
        #expect(index.search(SearchQuery(text: "galaxy", tags: ["cockpit"])).aftermarketItems.isEmpty)
    }
}

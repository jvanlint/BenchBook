import AppKit
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import BenchBook

struct PageInfoParsingTests {
    let base = URL(string: "https://www.britmodeller.com/forums/topic/123-f-16/")!

    @Test func readsOpenGraphAndTwitterTags() {
        let html = #"""
        <html><head>
        <title>Ignored when og:title exists</title>
        <meta property="og:title" content="Tamiya F-16C &#8211; WIP &amp; Done">
        <meta content="Britmodeller.com" property="og:site_name" />
        <meta name="description" content="  Cockpit   finished,
           intakes next. ">
        <meta property='og:image' content='/uploads/f16.jpg'>
        <meta name="twitter:image" content="https://cdn.example.com/f16-card.jpg">
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-icon.png">
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="shortcut icon" sizes="32x32" href="/favicon-32.png">
        <link rel="icon" sizes="96x96" href="/favicon-96.png">
        </head><body><meta property="og:image" content="/body-image.jpg"></body></html>
        """#
        let info = PageInfoFetcher.parse(html, baseURL: base)
        #expect(info.title == "Tamiya F-16C – WIP & Done")
        #expect(info.siteName == "Britmodeller.com")
        #expect(info.description == "Cockpit finished, intakes next.")
        #expect(info.imageURLs == [
            URL(string: "https://www.britmodeller.com/uploads/f16.jpg")!,
            URL(string: "https://cdn.example.com/f16-card.jpg")!,
        ])
        #expect(info.iconURLs == [
            URL(string: "https://www.britmodeller.com/apple-icon.png")!,
            URL(string: "https://www.britmodeller.com/favicon-96.png")!,
            URL(string: "https://www.britmodeller.com/favicon-32.png")!,
        ])
    }

    @Test func fallsBackToTheTitleElement() {
        let info = PageInfoFetcher.parse("<HEAD><Title>\n  Hannants &ndash; Paints\n</Title></HEAD>", baseURL: base)
        #expect(info.title == "Hannants – Paints")
        #expect(info.imageURLs.isEmpty)
        #expect(info.siteName == nil)
    }

    @Test func ignoresNonWebImageLinks() {
        let info = PageInfoFetcher.parse(#"<meta property="og:image" content="data:image/png;base64,AAAA">"#, baseURL: base)
        #expect(info.imageURLs.isEmpty)
    }

    @Test func decodesEntities() {
        #expect(PageInfoFetcher.decodeEntities("Rock &amp; Roll &#x27;n&#39; &rsquo;s &bogus;") == "Rock & Roll 'n' ’s &bogus;")
    }

    @Test func scalesImagesAndRejectsTinyOnes() throws {
        let folder = try TemporaryFolder()
        let large = try Data(contentsOf: Fixtures.writePNG(to: folder.file("large.png"), width: 2000, height: 1000))
        let scaled = try #require(PageInfoFetcher.scaledImage(large, minPixels: 100, maxPixels: 960))
        let source = try #require(CGImageSourceCreateWithData(scaled as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 960)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 480)

        let pixel = try Data(contentsOf: Fixtures.writePNG(to: folder.file("pixel.png"), width: 1, height: 1))
        #expect(PageInfoFetcher.scaledImage(pixel, minPixels: 100, maxPixels: 960) == nil)
        #expect(PageInfoFetcher.scaledImage(Data("not an image".utf8), minPixels: 1, maxPixels: 960) == nil)
    }
}

@MainActor
struct PageInfoServiceTests {
    let container: ModelContainer
    let folder: TemporaryFolder
    var context: ModelContext { container.mainContext }
    var library: AssetLibrary { AssetLibrary(rootURL: folder.url) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
        folder = try TemporaryFolder()
    }

    private func webpage(_ url: String, title: String? = nil) throws -> Reference {
        let project = Fixtures.makeProject("F-16", in: context)
        let reference = Reference(project: project, kind: .webpage, title: title, sourcePageURL: URL(string: url)!)
        context.insert(reference)
        try context.save()
        return reference
    }

    private func image(width: Int, height: Int) throws -> Data {
        try Data(contentsOf: Fixtures.writePNG(to: folder.file("\(UUID()).png"), width: width, height: height))
    }

    private func pixelSize(of url: URL) throws -> (Int, Int) {
        let image = try #require(NSImage(contentsOf: url)?.representations.first)
        return (image.pixelsWide, image.pixelsHigh)
    }

    @Test func savesPreviewImageAndDetails() async throws {
        let web = StubWeb()
        web.add("https://example.com/card.jpg", try image(width: 1200, height: 630))
        web.add("https://example.com/", contentType: "text/html", Data(#"""
            <meta property="og:title" content="Weathering an F-16"><meta property="og:site_name" content="Example">
            <meta property="og:description" content="Oils over a gloss coat."><meta property="og:image" content="/card.jpg">
            """#.utf8))
        let reference = try webpage("https://example.com/weathering", title: "example.com")
        let service = LinkInfoService(context: context, library: library, pageFetcher: web.pageFetcher)

        await service.refresh(reference)

        #expect(reference.title == "Weathering an F-16")
        #expect(reference.linkSiteName == "Example")
        #expect(reference.linkDescription == "Oils over a gloss coat.")
        #expect(reference.linkPreviewFetchedAt != nil)
        #expect(!context.hasChanges)
        let poster = library.posterURL(referenceID: reference.id)
        #expect(try pixelSize(of: poster) == (960, 504))
        #expect(NSImage(contentsOf: poster)?.looksLikeIcon == false)
    }

    @Test func usesTheSiteIconWhenThereIsNoPreviewImage() async throws {
        let web = StubWeb()
        web.add("https://example.com/apple-touch-icon.png", try image(width: 512, height: 512))
        web.add("https://example.com/", contentType: "text/html", Data("<title>Paint chart</title>".utf8))
        let reference = try webpage("https://example.com/paints", title: "My paint notes")

        await LinkInfoService(context: context, library: library, pageFetcher: web.pageFetcher).refresh(reference)

        #expect(reference.title == "My paint notes")  // typed titles are kept
        let poster = library.posterURL(referenceID: reference.id)
        #expect(try pixelSize(of: poster) == (192, 192))
        #expect(NSImage(contentsOf: poster)?.looksLikeIcon == true)
    }

    @Test func linkToAnImageIsItsOwnPreview() async throws {
        let web = StubWeb()
        web.add("https://example.com/photo.png", contentType: "image/png", try image(width: 400, height: 300))
        let reference = try webpage("https://example.com/photo.png")

        await LinkInfoService(context: context, library: library, pageFetcher: web.pageFetcher).refresh(reference)

        #expect(try pixelSize(of: library.posterURL(referenceID: reference.id)) == (400, 300))
    }

    @Test func missingPageIsNotRetriedButOfflineIs() async throws {
        let web = StubWeb()  // every request is a 404
        let gone = try webpage("https://example.com/gone")
        let service = LinkInfoService(context: context, library: library, pageFetcher: web.pageFetcher)
        await service.refresh(gone)
        #expect(gone.linkPreviewFetchedAt != nil)
        #expect(gone.linkSiteName == nil)

        web.offline = true
        let later = try webpage("https://example.com/later")
        await service.refresh(later)
        #expect(later.linkPreviewFetchedAt == nil)
    }

    @Test func titleReplacementRules() {
        #expect(LinkInfoService.shouldReplaceTitle("www.example.com", host: "www.example.com"))
        #expect(LinkInfoService.shouldReplaceTitle("https://www.example.com/a", host: "www.example.com"))
        #expect(!LinkInfoService.shouldReplaceTitle("Example", host: "www.example.com"))
    }
}

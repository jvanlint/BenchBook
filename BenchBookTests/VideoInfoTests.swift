import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct VideoInfoParsingTests {
    @Test func readsYouTubeOEmbed() throws {
        let json = #"{"title":"Rick Astley - Never Gonna Give You Up","author_name":"Rick Astley","author_url":"https://www.youtube.com/@RickAstleyYT","thumbnail_url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"}"#
        let info = try #require(VideoInfoFetcher.parseOEmbed(Data(json.utf8)))
        #expect(info.title == "Rick Astley - Never Gonna Give You Up")
        #expect(info.channel == "Rick Astley")
        #expect(info.channelURL == URL(string: "https://www.youtube.com/@RickAstleyYT"))
        #expect(info.durationSeconds == nil)
    }

    @Test func readsVimeoOEmbed() throws {
        let json = #"{"title":"The New Vimeo Player","author_name":"Vimeo","author_url":"https:\/\/vimeo.com\/staff","duration":62,"description":"Line one\nLine two","thumbnail_url":"https:\/\/i.vimeocdn.com\/video\/1-d_1280","upload_date":"2013-10-15 14:08:29"}"#
        let info = try #require(VideoInfoFetcher.parseOEmbed(Data(json.utf8)))
        #expect(info.durationSeconds == 62)
        #expect(info.description == "Line one\nLine two")
        #expect(info.thumbnailURLs == [URL(string: "https://i.vimeocdn.com/video/1-d_1280")!])
        #expect(info.publishedAt == ISO8601DateFormatter().date(from: "2013-10-15T14:08:29Z"))
    }

    @Test func readsYouTubeWatchPage() throws {
        let html = #"""
        <meta name="title" content="Tamiya 1/48 F-16 &quot;Viper&quot; build">
        <meta itemprop="duration" content="PT3M34S"><meta itemprop="datePublished" content="2009-10-24T23:57:33-07:00">
        ..."lengthSeconds":"213",..."ownerChannelName":"Plasmo",..."shortDescription":"Part 1 of the build.\n\nPaints: \"XF-54\" and H-335",...
        """#
        let info = VideoInfoFetcher.parseYouTubePage(html)
        #expect(info.title == "Tamiya 1/48 F-16 \"Viper\" build")
        #expect(info.channel == "Plasmo")
        #expect(info.durationSeconds == 213)
        #expect(info.description == "Part 1 of the build.\n\nPaints: \"XF-54\" and H-335")
        #expect(info.publishedAt == ISO8601DateFormatter().date(from: "2009-10-25T06:57:33Z"))
    }

    @Test func pageWithoutDetailsGivesNothing() {
        let info = VideoInfoFetcher.parseYouTubePage("<html><body>Before you continue to YouTube</body></html>")
        #expect(info == VideoInfo())
    }

    @Test func parsesDurations() {
        #expect(VideoInfoFetcher.parseISODuration("PT3M34S") == 214)
        #expect(VideoInfoFetcher.parseISODuration("PT1H2M3S") == 3723)
        #expect(VideoInfoFetcher.parseISODuration("P1DT1S") == 86_401)
        #expect(VideoInfoFetcher.parseISODuration("PT0S") == nil)
        #expect(VideoInfoFetcher.parseISODuration("3:34") == nil)
    }

    @Test func keepsTypedTitlesOnly() {
        #expect(LinkInfoService.shouldReplaceTitle(nil))
        #expect(LinkInfoService.shouldReplaceTitle("  "))
        #expect(LinkInfoService.shouldReplaceTitle("F-16 Viper build part 1 - YouTube"))
        #expect(LinkInfoService.shouldReplaceTitle("https://youtu.be/dQw4w9WgXcQ"))
        #expect(!LinkInfoService.shouldReplaceTitle("Weathering the intakes"))
    }
}

/// Fake network: answers by URL prefix and records requests.
nonisolated final class StubWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(prefix: String, status: Int, contentType: String?, body: Data)] = []
    private var isOffline = false
    private var log: [URL] = []

    var offline: Bool {
        get { lock.withLock { isOffline } }
        set { lock.withLock { isOffline = newValue } }
    }

    var requested: [URL] { lock.withLock { log } }

    /// Earlier prefixes win, so add specific ones first.
    func add(_ prefix: String, status: Int = 200, contentType: String? = nil, _ body: Data) {
        lock.withLock { responses.append((prefix, status, contentType, body)) }
    }

    var fetcher: VideoInfoFetcher {
        VideoInfoFetcher { [self] request in try respond(to: request.url!) }
    }

    var pageFetcher: PageInfoFetcher {
        PageInfoFetcher { [self] request in try respond(to: request.url!) }
    }

    private func respond(to url: URL) throws -> (Data, URLResponse) {
        try lock.withLock {
            log.append(url)
            if isOffline { throw URLError(.notConnectedToInternet) }
            let match = responses.first { url.absoluteString.hasPrefix($0.prefix) }
            let headers = match?.contentType.map { ["Content-Type": $0] }
            let response = HTTPURLResponse(url: url, statusCode: match?.status ?? 404, httpVersion: nil, headerFields: headers)!
            return (match?.body ?? Data(), response)
        }
    }
}

@MainActor
struct VideoInfoServiceTests {
    let container: ModelContainer
    let folder: TemporaryFolder
    var context: ModelContext { container.mainContext }
    var library: AssetLibrary { AssetLibrary(rootURL: folder.url) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
        folder = try TemporaryFolder()
    }

    private func videoLink(_ url: String, title: String? = nil) throws -> Reference {
        let project = Fixtures.makeProject("F-16", in: context)
        let reference = Reference(project: project, kind: .videoLink, title: title, sourcePageURL: URL(string: url)!)
        context.insert(reference)
        try context.save()
        return reference
    }

    private func youTubeWeb() throws -> StubWeb {
        let web = StubWeb()
        let jpeg = try Data(contentsOf: Fixtures.writeJPEG(to: folder.file("poster.jpg")))
        web.add("https://www.youtube.com/oembed", Data(#"{"title":"Masking a canopy","author_name":"Plasmo","author_url":"https://www.youtube.com/@plasmo"}"#.utf8))
        web.add("https://www.youtube.com/watch", Data(#"<meta itemprop="datePublished" content="2024-05-01">"lengthSeconds":"754","shortDescription":"Tape first.","x"#.utf8))
        web.add("https://i.ytimg.com/vi/abc123DEF45/hqdefault.jpg", jpeg)  // no maxres for this one
        return web
    }

    @Test func fillsInDetailsAndPoster() async throws {
        let web = try youTubeWeb()
        let reference = try videoLink("https://youtu.be/abc123DEF45?t=90", title: "Masking a canopy - YouTube")
        let service = LinkInfoService(context: context, library: library, fetcher: web.fetcher)

        await service.refresh(reference)

        #expect(reference.title == "Masking a canopy")
        #expect(reference.videoChannel == "Plasmo")
        #expect(reference.videoDurationSeconds == 754)
        #expect(reference.videoDescription == "Tape first.")
        #expect(reference.videoPublishedAt != nil)
        #expect(reference.videoInfoFetchedAt != nil)
        #expect(!context.hasChanges)
        #expect(FileManager.default.fileExists(atPath: library.posterURL(referenceID: reference.id).path))
        #expect(web.requested.contains(URL(string: "https://i.ytimg.com/vi/abc123DEF45/maxresdefault.jpg")!))
    }

    @Test func keepsTheUsersTitle() async throws {
        let reference = try videoLink("https://www.youtube.com/watch?v=abc123DEF45", title: "Canopy masking tips")
        await LinkInfoService(context: context, library: library, fetcher: try youTubeWeb().fetcher).refresh(reference)
        #expect(reference.title == "Canopy masking tips")
        #expect(reference.videoChannel == "Plasmo")
    }

    @Test func offlineTriesAgainLater() async throws {
        let web = try youTubeWeb()
        web.offline = true
        let reference = try videoLink("https://youtu.be/abc123DEF45")
        let service = LinkInfoService(context: context, library: library, fetcher: web.fetcher)

        await service.refresh(reference)
        #expect(reference.videoInfoFetchedAt == nil)

        web.offline = false
        service.fetchMissing()
        try await waitUntil { reference.videoInfoFetchedAt != nil }
        #expect(reference.title == "Masking a canopy")
    }

    @Test func removedVideoIsNotRetried() async throws {
        let web = StubWeb()  // every request is a 404
        let reference = try videoLink("https://vimeo.com/76979871")
        await LinkInfoService(context: context, library: library, fetcher: web.fetcher).refresh(reference)

        #expect(reference.videoInfoFetchedAt != nil)
        #expect(reference.videoChannel == nil)
        #expect(reference.title == nil)
    }

    @Test func deletingRemovesThePoster() async throws {
        let reference = try videoLink("https://youtu.be/abc123DEF45")
        await LinkInfoService(context: context, library: library, fetcher: try youTubeWeb().fetcher).refresh(reference)
        let poster = library.posterURL(referenceID: reference.id)
        #expect(FileManager.default.fileExists(atPath: poster.path))

        try ReferenceService(context: context, library: library).delete(reference)
        #expect(!FileManager.default.fileExists(atPath: poster.path))
    }

    @Test func reconcileRemovesPostersOfDeletedProjects() async throws {
        let reference = try videoLink("https://youtu.be/abc123DEF45")
        await LinkInfoService(context: context, library: library, fetcher: try youTubeWeb().fetcher).refresh(reference)
        let poster = library.posterURL(referenceID: reference.id)

        context.delete(try #require(reference.project))
        try context.save()
        try ReferenceService(context: context, library: library).reconcileLibrary()
        #expect(!FileManager.default.fileExists(atPath: poster.path))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

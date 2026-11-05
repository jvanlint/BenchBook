import Foundation
import ImageIO

/// Public details about a video. Any field can be missing.
nonisolated struct VideoInfo: Equatable, Sendable {
    var title: String?
    var channel: String?
    var channelURL: URL?
    var durationSeconds: Double?
    var publishedAt: Date?
    var description: String?
    /// Poster images to try, best first.
    var thumbnailURLs: [URL] = []

    var isEmpty: Bool {
        title == nil && channel == nil && durationSeconds == nil && thumbnailURLs.isEmpty
    }
}

nonisolated enum LinkInfoError: Error, Equatable {
    /// The site says the video doesn't exist or is private. Not retried.
    case notFound
    /// Offline, timed out or a server error. Tried again later.
    case unavailable
}

/// Fetches a YouTube or Vimeo video's title, channel, poster image, length,
/// publish date and description from the sites' public pages. No account
/// or API key is needed. Never downloads the video itself.
nonisolated struct VideoInfoFetcher: Sendable {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxDescriptionLength = 5_000

    var load: Load = { request in try await URLSession.shared.data(for: request) }

    func info(for video: VideoLink.Parsed) async throws -> VideoInfo {
        switch video.provider {
        case .youtube: try await youTubeInfo(id: video.videoID)
        case .vimeo: try await vimeoInfo(id: video.videoID)
        }
    }

    /// The first poster image that downloads and decodes.
    func thumbnail(for info: VideoInfo) async -> Data? {
        for url in info.thumbnailURLs {
            guard let (data, status) = try? await get(url), status == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0
            else { continue }
            return data
        }
        return nil
    }

    // MARK: - Sites

    private func youTubeInfo(id: String) async throws -> VideoInfo {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(id)")!
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: watchURL.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]

        // oEmbed refuses videos that can't be embedded, but the watch page
        // still has their details, so a refusal isn't the end.
        let (oEmbedData, oEmbedStatus) = try await get(components.url!)
        var info = oEmbedStatus == 200 ? Self.parseOEmbed(oEmbedData) ?? VideoInfo() : VideoInfo()
        if oEmbedStatus >= 500 { throw LinkInfoError.unavailable }

        if let (pageData, pageStatus) = try? await get(watchURL), pageStatus == 200 {
            let page = Self.parseYouTubePage(String(decoding: pageData, as: UTF8.self))
            info.title = info.title ?? page.title
            info.channel = info.channel ?? page.channel
            info.durationSeconds = page.durationSeconds
            info.publishedAt = page.publishedAt
            info.description = page.description
        }
        guard info.title != nil || info.durationSeconds != nil else {
            throw LinkInfoError.notFound
        }
        // maxresdefault is 1280×720 but missing for some older videos;
        // hqdefault always exists (480×360, letterboxed).
        info.thumbnailURLs = [
            URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")!,
            URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!,
        ]
        return info
    }

    private func vimeoInfo(id: String) async throws -> VideoInfo {
        var components = URLComponents(string: "https://vimeo.com/api/oembed.json")!
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://vimeo.com/\(id)"),
            URLQueryItem(name: "width", value: "1280"),  // asks for a larger poster
        ]
        let (data, status) = try await get(components.url!)
        switch status {
        case 200: break
        case 400..<500: throw LinkInfoError.notFound
        default: throw LinkInfoError.unavailable
        }
        guard let info = Self.parseOEmbed(data) else { throw LinkInfoError.notFound }
        return info
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        // Skips YouTube's cookie-consent page in some regions.
        request.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await load(request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        } catch {
            throw LinkInfoError.unavailable
        }
    }

    // MARK: - Parsing

    /// Reads an oEmbed response (YouTube or Vimeo).
    static func parseOEmbed(_ data: Data) -> VideoInfo? {
        struct OEmbed: Decodable {
            var title: String?
            var author_name: String?
            var author_url: String?
            var thumbnail_url: String?
            var duration: Double?
            var upload_date: String?
            var description: String?
        }
        guard let oEmbed = try? JSONDecoder().decode(OEmbed.self, from: data) else { return nil }
        return VideoInfo(
            title: oEmbed.title?.trimmedOrNil,
            channel: oEmbed.author_name?.trimmedOrNil,
            channelURL: oEmbed.author_url.flatMap(URL.init(string:)),
            durationSeconds: oEmbed.duration.flatMap { $0 > 0 ? $0 : nil },
            publishedAt: oEmbed.upload_date.flatMap(parseDate),
            description: oEmbed.description.flatMap(cleanDescription),
            thumbnailURLs: oEmbed.thumbnail_url.flatMap(URL.init(string:)).map { [$0] } ?? []
        )
    }

    /// Reads details from a YouTube watch page. Missing pieces stay nil, so
    /// a page layout change degrades quietly.
    static func parseYouTubePage(_ html: String) -> VideoInfo {
        var info = VideoInfo()
        if let seconds = firstMatch(#""lengthSeconds":"(\d+)""#, in: html).flatMap(Double.init), seconds > 0 {
            info.durationSeconds = seconds
        } else if let iso = metaContent(itemprop: "duration", in: html) {
            info.durationSeconds = parseISODuration(iso)
        }
        info.publishedAt = (metaContent(itemprop: "datePublished", in: html)
            ?? firstMatch(#""publishDate":"([^"]+)""#, in: html)).flatMap(parseDate)
        if let escaped = firstMatch(#""shortDescription":"((?:[^"\\]|\\.)*)""#, in: html),
           let decoded = try? JSONDecoder().decode(String.self, from: Data("\"\(escaped)\"".utf8)) {
            info.description = cleanDescription(decoded)
        }
        info.title = firstMatch(#"<meta name="title" content="([^"]*)""#, in: html).map(decodeEntities)?.trimmedOrNil
        info.channel = firstMatch(#""ownerChannelName":"((?:[^"\\]|\\.)*)""#, in: html)?.trimmedOrNil
        return info
    }

    /// "PT3M34S", "PT1H2M3S" or "P0DT45S" as seconds.
    static func parseISODuration(_ text: String) -> Double? {
        guard text.hasPrefix("P") else { return nil }
        var total = 0.0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character == "T" { inTime = true; continue }
            if character.isNumber || character == "." { number.append(character); continue }
            guard let value = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
        }
        return number.isEmpty && total > 0 ? total : nil
    }

    /// ISO 8601 with time zone, a plain date, or Vimeo's "2013-10-15 14:08:29" (UTC).
    static func parseDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        if let date = full.date(from: text.replacingOccurrences(of: " ", with: "T") + "Z") { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: String(text.prefix(10)))
    }

    private static func cleanDescription(_ text: String) -> String? {
        text.trimmedOrNil.map { String($0.prefix(maxDescriptionLength)) }
    }

    private static func metaContent(itemprop: String, in html: String) -> String? {
        firstMatch(#"<meta itemprop="\#(itemprop)" content="([^"]*)""#, in: html)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? Regex(pattern),
              let match = text.firstMatch(of: regex),
              match.output.count > 1,
              let captured = match.output[1].substring
        else { return nil }
        return String(captured)
    }

    private static func decodeEntities(_ text: String) -> String {
        [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

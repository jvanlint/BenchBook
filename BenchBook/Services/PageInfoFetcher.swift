import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a webpage says about itself for link previews. Any field can be missing.
nonisolated struct PageInfo: Equatable, Sendable {
    var title: String?
    var siteName: String?
    var description: String?
    /// Preview images the page names (Open Graph, Twitter cards), best first.
    var imageURLs: [URL] = []
    /// The site's icons, best first. Used when there's no preview image.
    var iconURLs: [URL] = []
}

/// A downloaded preview image, scaled down and ready to store.
nonisolated struct PagePreviewImage: Equatable, Sendable {
    var data: Data
    /// A site icon rather than a picture of the page's content.
    var isIcon: Bool
}

/// Fetches a webpage's preview image, title, site name and description: the
/// same details Messages and Safari use for link previews. Reads only the
/// page's HTML header; never runs the page's scripts.
nonisolated struct PageInfoFetcher: Sendable {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxDescriptionLength = 2_000
    /// Preview images are stored no larger than this, on the longer side.
    static let maxImagePixels = 960
    static let maxIconPixels = 192
    /// Smaller images are usually tracking pixels or spacers.
    static let minImagePixels = 100
    /// Smaller icons look blurry scaled up in a tile.
    static let minIconPixels = 64

    var load: Load = { request in try await URLSession.shared.data(for: request) }

    func info(for url: URL) async throws -> PageInfo {
        let (data, response) = try await get(url, accept: "text/html,application/xhtml+xml,*/*;q=0.8")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 200..<300: break
        case 400..<500: throw LinkInfoError.notFound
        default: throw LinkInfoError.unavailable
        }
        let finalURL = response.url ?? url

        // A link straight to an image is its own preview.
        if let mimeType = response.mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .image) {
            return PageInfo(title: nil, imageURLs: [finalURL])
        }
        var info = Self.parse(String(decoding: data.prefix(1_000_000), as: UTF8.self), baseURL: finalURL)
        if let origin = URL(string: "/", relativeTo: finalURL)?.absoluteURL {
            // Most sites have these even when the page doesn't list them.
            info.iconURLs += ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: $0, relativeTo: origin)?.absoluteURL }
        }
        info.iconURLs = Self.unique(info.iconURLs)
        return info
    }

    /// The first preview image that downloads and decodes, else the first icon.
    func previewImage(for info: PageInfo) async -> PagePreviewImage? {
        for url in info.imageURLs {
            if let data = await image(at: url, minPixels: Self.minImagePixels, maxPixels: Self.maxImagePixels) {
                return PagePreviewImage(data: data, isIcon: false)
            }
        }
        for url in info.iconURLs {
            if let data = await image(at: url, minPixels: Self.minIconPixels, maxPixels: Self.maxIconPixels) {
                return PagePreviewImage(data: data, isIcon: true)
            }
        }
        return nil
    }

    private func image(at url: URL, minPixels: Int, maxPixels: Int) async -> Data? {
        guard let (data, response) = try? await get(url, accept: "image/*"),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return Self.scaledImage(data, minPixels: minPixels, maxPixels: maxPixels)
    }

    private func get(_ url: URL, accept: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        // Says honestly what's asking. Sites that refuse automated requests
        // just get no preview.
        request.setValue("BenchBook (link preview)", forHTTPHeaderField: "User-Agent")
        do {
            return try await load(request)
        } catch {
            throw LinkInfoError.unavailable
        }
    }

    // MARK: - Images

    /// Decodes an image, picks its largest frame (icons often have several)
    /// and scales it down to `maxPixels`. JPEG, or PNG if it's transparent.
    /// Nil if it isn't an image or is smaller than `minPixels`.
    static func scaledImage(_ data: Data, minPixels: Int, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        func pixelSize(at index: Int) -> (Int, Int) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        let index = (0..<count).max { pixelSize(at: $0).0 < pixelSize(at: $1).0 } ?? 0
        let (width, height) = pixelSize(at: index)
        guard min(width, height) >= minPixels else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }

        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        let type = isOpaque ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Parsing

    /// Reads preview details from a page's HTML. Missing pieces stay nil.
    static func parse(_ html: String, baseURL: URL) -> PageInfo {
        // Everything needed is in the header; the body can hold misleading tags.
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html

        var meta: [String: String] = [:]
        var links: [(rel: Set<String>, href: String, sizes: Int, type: String)] = []
        for (name, attributes) in tags(in: head) {
            if name == "meta", let content = attributes["content"].map(decodeEntities)?.trimmedOrNil,
               let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
               meta[key] == nil {
                meta[key] = content
            } else if name == "link", let href = attributes["href"].map(decodeEntities)?.trimmedOrNil {
                let rel = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
                // "180x180", "32x32 16x16" or "any": the largest width.
                let sizes = (attributes["sizes"] ?? "").split(separator: " ")
                    .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max() ?? 0
                links.append((rel, href, sizes, (attributes["type"] ?? "").lowercased()))
            }
        }

        func first(_ keys: String...) -> String? {
            keys.lazy.compactMap { meta[$0] }.first
        }
        func resolve(_ text: String) -> URL? {
            guard let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
            else { return nil }
            return url
        }

        var info = PageInfo()
        info.title = (first("og:title", "twitter:title") ?? titleElement(in: head)).map(collapseWhitespace)
        info.siteName = first("og:site_name", "application-name", "apple-mobile-web-app-title").map(collapseWhitespace)
        info.description = first("og:description", "description", "twitter:description")
            .map { String(collapseWhitespace($0).prefix(maxDescriptionLength)) }

        let imageTexts = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src", "image"]
            .compactMap { meta[$0] } + links.filter { $0.rel.contains("image_src") }.map(\.href)
        info.imageURLs = unique(imageTexts.compactMap(resolve))

        // Apple touch icons are large and opaque; then other icons, largest
        // first. SVG icons can't be decoded here.
        let icons = links.filter { link in
            (link.rel.contains("icon") || link.rel.contains { $0.hasPrefix("apple-touch-icon") })
                && !link.type.contains("svg") && !link.href.lowercased().hasSuffix(".svg")
        }
        let ranked = icons.sorted { lhs, rhs in
            let lhsApple = lhs.rel.contains { $0.hasPrefix("apple-touch-icon") }
            let rhsApple = rhs.rel.contains { $0.hasPrefix("apple-touch-icon") }
            return lhsApple != rhsApple ? lhsApple : lhs.sizes > rhs.sizes
        }
        info.iconURLs = unique(ranked.compactMap { resolve($0.href) })
        return info
    }

    /// Every `<meta>` and `<link>` tag, with its attributes (names lowercased).
    private static func tags(in html: String) -> [(name: String, attributes: [String: String])] {
        guard let tagRegex = try? Regex(#"<(meta|link)\b([^>]*)>"#).ignoresCase(),
              let attributeRegex = try? Regex(#"([a-zA-Z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
        else { return [] }
        return html.matches(of: tagRegex).compactMap { match in
            guard let name = match.output[1].substring, let body = match.output[2].substring else { return nil }
            var attributes: [String: String] = [:]
            for attribute in body.matches(of: attributeRegex) {
                guard let key = attribute.output[1].substring else { continue }
                let value = (2...4).lazy.compactMap { attribute.output[$0].substring }.first ?? ""
                attributes[key.lowercased()] = attributes[key.lowercased()] ?? String(value)
            }
            return (name.lowercased(), attributes)
        }
    }

    private static func titleElement(in html: String) -> String? {
        guard let regex = try? Regex(#"<title\b[^>]*>([^<]*)</title>"#).ignoresCase(),
              let text = html.firstMatch(of: regex)?.output[1].substring
        else { return nil }
        return decodeEntities(String(text)).trimmedOrNil
    }

    /// Decodes named entities common in titles, plus numeric ones like &#8217;.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = try? Regex(#"&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…",
        ]
        return text.replacing(regex) { match in
            let entity = String(match.output[1].substring ?? "")
            if entity.hasPrefix("#") {
                let digits = entity.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
            } else if let character = named[entity] {
                return character
            }
            return String(match.output[0].substring ?? "")
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

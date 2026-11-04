import Foundation

/// Recognises video links and their timestamps, and builds playback links.
nonisolated enum VideoLink {
    enum Provider: Equatable {
        case youtube
        case vimeo
    }

    struct Parsed: Equatable {
        var provider: Provider
        var videoID: String
        /// Seconds from the start, when the link carries a timestamp.
        var startSeconds: Double?
    }

    static func parse(_ url: URL) -> Parsed? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return nil }

        let pathParts = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        let timestamp = query.first { $0.name == "t" || $0.name == "start" }?.value
            ?? fragmentTimestamp(components.fragment)

        if ["youtu.be", "www.youtu.be"].contains(host) {
            guard let id = pathParts.first, isPlausibleID(id) else { return nil }
            return Parsed(provider: .youtube, videoID: id, startSeconds: timestamp.flatMap(parseTimestamp))
        }

        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "www.youtube-nocookie.com"]
        if youtubeHosts.contains(host) {
            var id: String?
            if pathParts.first == "watch" {
                id = query.first { $0.name == "v" }?.value
            } else if let first = pathParts.first, ["shorts", "live", "embed", "v"].contains(first), pathParts.count > 1 {
                id = pathParts[1]
            }
            guard let id, isPlausibleID(id) else { return nil }
            return Parsed(provider: .youtube, videoID: id, startSeconds: timestamp.flatMap(parseTimestamp))
        }

        if ["vimeo.com", "www.vimeo.com", "player.vimeo.com"].contains(host),
           let id = pathParts.last(where: { $0.allSatisfy(\.isNumber) }) {
            return Parsed(provider: .vimeo, videoID: id, startSeconds: timestamp.flatMap(parseTimestamp))
        }
        return nil
    }

    /// Accepts "90", "90s", "1m30s", "1h2m3s" and "1:30" / "1:02:03".
    static func parseTimestamp(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        if let seconds = Double(text) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }

        var total = 0.0
        var number = ""
        var sawUnit = false
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let amount = Double(number) else { return nil }
            switch character {
            case "h": total += amount * 3600
            case "m": total += amount * 60
            case "s": total += amount
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit, total.isFinite else { return nil }
        return total
    }

    /// A link that opens the video at `seconds`. Unknown providers get the original link.
    static func playbackURL(for sourceURL: URL, at seconds: Double) -> URL {
        guard let parsed = parse(sourceURL) else { return sourceURL }
        let whole = max(0, Int(seconds.rounded(.down)))
        switch parsed.provider {
        case .youtube:
            var components = URLComponents(string: "https://www.youtube.com/watch")!
            components.queryItems = [
                URLQueryItem(name: "v", value: parsed.videoID),
                URLQueryItem(name: "t", value: "\(whole)s"),
            ]
            return components.url ?? sourceURL
        case .vimeo:
            return URL(string: "https://vimeo.com/\(parsed.videoID)#t=\(whole)s") ?? sourceURL
        }
    }

    /// "0:45", "12:03" or "1:02:03".
    static func format(seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func fragmentTimestamp(_ fragment: String?) -> String? {
        guard let fragment, fragment.hasPrefix("t=") else { return nil }
        return String(fragment.dropFirst(2))
    }

    private static func isPlausibleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

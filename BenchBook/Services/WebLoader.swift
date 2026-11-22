import Darwin
import Foundation

/// Downloads for link previews. Stops reading at a size limit, follows
/// redirects only to public web addresses, and refuses addresses a website
/// gave (preview images, icons) unless they're public too. So a page can't
/// make BenchBook fetch something on the local network, such as a router.
nonisolated struct WebLoader: Sendable {
    struct Rules: Sendable, Equatable {
        /// Reading stops here; what was read so far is returned.
        var maxBytes: Int
        /// The address came from a website rather than the user.
        var publicOnly: Bool

        /// A page the user saved. Only its header is read for previews.
        static let page = Rules(maxBytes: 1_000_000, publicOnly: false)
        /// An image or icon a page names.
        static let pageImage = Rules(maxBytes: 10_000_000, publicOnly: true)
        /// YouTube and Vimeo pages and posters. Watch pages are large.
        static let video = Rules(maxBytes: 5_000_000, publicOnly: true)
    }

    enum LoadError: Error, Equatable {
        case notAllowed
    }

    var session: URLSession = .shared

    func load(_ request: URLRequest, rules: Rules) async throws -> (Data, URLResponse) {
        guard let url = request.url, Self.isWebAddress(url),
              !rules.publicOnly || Self.isPublicWebAddress(url)
        else { throw LoadError.notAllowed }

        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        defer { bytes.task.cancel() }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), rules.maxBytes))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count >= rules.maxBytes { break }
        }
        return (data, response)
    }

    // MARK: - Addresses

    static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host(percentEncoded: false) ?? "").isEmpty
    }

    /// An http or https address on the public internet: not this Mac, not
    /// the local network, and not a name that only works there.
    static func isPublicWebAddress(_ url: URL) -> Bool {
        guard isWebAddress(url), var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }

        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return isPublic(ipv4: UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return isPublic(ipv6: v6) }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A single name ("router") or an empty label only resolves locally.
        guard labels.count > 1, !labels.contains(where: \.isEmpty), let last = labels.last else { return false }
        // No real top-level domain is a number, so this is an address in a
        // form inet_pton doesn't read ("127.1", "2130706433", "0x7f.0.0.1").
        if last.allSatisfy(\.isNumber) || last.hasPrefix("0x") { return false }
        let localSuffixes = ["localhost", "local", "internal", "lan", "home.arpa", "localdomain"]
        return !localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isPublic(ipv4 address: UInt32) -> Bool {
        let a = address >> 24, b = (address >> 16) & 0xFF
        switch a {
        case 0, 10, 127: return false                // this network, private, loopback
        case 100 where (64...127).contains(b): return false  // carrier-grade NAT
        case 169 where b == 254: return false        // link-local
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 192 where b == 0 && (address >> 8) & 0xFF == 0: return false
        case 198 where b == 18 || b == 19: return false  // benchmarking
        case 224...: return false                    // multicast and reserved
        default: return true
        }
    }

    private static func isPublic(ipv6 address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address.__u6_addr.__u6_addr8) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return false }                         // ::
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false } // ::1
        if bytes[0] & 0xFE == 0xFC { return false }                               // unique local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }           // link-local
        if bytes[0] == 0xFF { return false }                                      // multicast
        // An IPv4 address written as IPv6 (::ffff:10.0.0.1).
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let v4 = bytes[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return isPublic(ipv4: v4)
        }
        return true
    }
}

/// Follows a redirect only to a public web address. Otherwise the redirect
/// response itself is returned, which callers treat as a failure.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// The request to follow a redirect with, or nil to stop there.
    static func follow(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, WebLoader.isPublicWebAddress(url) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.follow(request))
    }
}

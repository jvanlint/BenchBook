import Foundation
import Testing
@testable import BenchBook

/// Serves canned responses by address and records what was asked for.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (status: Int, type: String, body: Data)] = [:]
    nonisolated(unsafe) private static var requested: [String] = []

    static func serve(_ address: String, status: Int = 200, type: String = "text/html", body: Data) {
        lock.withLock { responses[address] = (status, type, body) }
    }

    static func wasRequested(_ address: String) -> Bool {
        lock.withLock { requested.contains(address) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let address = url.absoluteString
        let canned = Self.lock.withLock {
            Self.requested.append(address)
            return Self.responses[address]
        } ?? (status: 404, type: "text/plain", body: Data())
        let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": canned.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct WebLoaderTests {
    @Test func tellsPublicAddressesFromLocalOnes() {
        let publicAddresses = [
            "https://www.scalemates.com/kits/123", "http://example.co.uk/a.png", "https://8.8.8.8/",
            "https://[2606:4700::1111]/", "https://172.32.0.1/", "https://shop.example.",
        ]
        for address in publicAddresses {
            #expect(WebLoader.isPublicWebAddress(URL(string: address)!), "\(address)")
        }
        let localAddresses = [
            "http://localhost/", "http://127.0.0.1/", "http://10.1.2.3/", "http://192.168.1.1/admin",
            "http://172.16.0.1/", "http://169.254.169.254/latest", "http://100.64.0.1/", "http://0.0.0.0/",
            "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:10.0.0.1]/",
            "http://router/", "http://nas.local/", "http://printer.lan/", "http://box.home.arpa/",
            "http://app.localhost/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/",
            "ftp://example.com/", "file:///etc/hosts",
        ]
        for address in localAddresses {
            #expect(!WebLoader.isPublicWebAddress(URL(string: address)!), "\(address)")
        }
    }

    @Test func redirectsGoOnlyToPublicAddresses() {
        let local = URLRequest(url: URL(string: "http://192.168.1.1/")!)
        let ftp = URLRequest(url: URL(string: "ftp://example.org/")!)
        let elsewhere = URLRequest(url: URL(string: "https://example.org/page")!)
        #expect(RedirectGuard.follow(local) == nil)
        #expect(RedirectGuard.follow(ftp) == nil)
        #expect(RedirectGuard.follow(elsewhere) == elsewhere)
    }

    @Test func stopsReadingAtTheLimit() async throws {
        StubURLProtocol.serve("https://big.example/page", body: Data(repeating: 0x61, count: 3_000_000))
        let loader = WebLoader(session: StubURLProtocol.session())
        let (data, _) = try await loader.load(URLRequest(url: URL(string: "https://big.example/page")!),
                                              rules: WebLoader.Rules(maxBytes: 1_000, publicOnly: false))
        #expect(data.count == 1_000)
    }

    @Test func refusesLocalAddressesFromAWebsite() async throws {
        let loader = WebLoader(session: StubURLProtocol.session())
        await #expect(throws: WebLoader.LoadError.notAllowed) {
            try await loader.load(URLRequest(url: URL(string: "http://10.0.0.1/icon.png")!), rules: .pageImage)
        }
        #expect(!StubURLProtocol.wasRequested("http://10.0.0.1/icon.png"))
        // A link the user saved may be on their own network.
        StubURLProtocol.serve("http://192.168.1.20/notes.html", body: Data("<title>NAS</title>".utf8))
        let (data, _) = try await loader.load(URLRequest(url: URL(string: "http://192.168.1.20/notes.html")!), rules: .page)
        #expect(String(decoding: data, as: UTF8.self) == "<title>NAS</title>")
    }

    @MainActor
    @Test func previewsSkipImagesOnTheLocalNetwork() async throws {
        let folder = try TemporaryFolder()
        let png = try Data(contentsOf: Fixtures.writePNG(to: folder.file("preview.png"), width: 300, height: 200))
        StubURLProtocol.serve("http://192.168.1.1/preview.png", type: "image/png", body: png)
        StubURLProtocol.serve("https://cdn.example/preview.png", type: "image/png", body: png)

        let session = StubURLProtocol.session()
        var fetcher = PageInfoFetcher()
        fetcher.load = { request, rules in try await WebLoader(session: session).load(request, rules: rules) }
        let info = PageInfo(imageURLs: [URL(string: "http://192.168.1.1/preview.png")!,
                                        URL(string: "https://cdn.example/preview.png")!])
        let preview = await fetcher.previewImage(for: info)
        #expect(preview?.isIcon == false)
        #expect(!StubURLProtocol.wasRequested("http://192.168.1.1/preview.png"))
        #expect(StubURLProtocol.wasRequested("https://cdn.example/preview.png"))
    }
}

import Foundation

/// One thing to save as a Reference, before it's validated and stored.
nonisolated enum CapturedItem: Hashable, Sendable {
    /// A local file to copy into the library. `originalFilename` is the name
    /// the user would recognise; `url` may point at a temporary copy.
    case file(url: URL, originalFilename: String?, resourceURL: URL?)
    case link(url: URL, title: String?)
    case text(String, sourceURL: URL?, title: String?)

    /// A short description for lists and error messages.
    var summary: String {
        switch self {
        case .file(let url, let originalFilename, _):
            originalFilename ?? url.lastPathComponent
        case .link(let url, let title):
            title ?? url.absoluteString
        case .text(let text, _, _):
            String(text.prefix(80))
        }
    }

    var systemImage: String {
        switch self {
        case .file(let url, let originalFilename, _):
            switch (originalFilename.map { ($0 as NSString).pathExtension } ?? url.pathExtension).lowercased() {
            case "pdf": "doc.richtext"
            case "md", "markdown", "mdown", "mkd": "doc.plaintext"
            default: "photo"
            }
        case .link: "link"
        case .text: "text.quote"
        }
    }
}

/// A capture handed from the Share extension to the app through the App
/// Group inbox. Each envelope is a folder:
///
///     Inbox/<id>/envelope.json
///     Inbox/<id>/<file>...       files named in `items`
///
/// The extension builds the folder under `Inbox/.staging/` and moves it into
/// place only when complete, so the app never sees a half-written capture.
///
/// Version 2 adds `source`, `pageURL` and `amends`. Each is optional, so
/// version 1 envelopes still read.
nonisolated struct CaptureEnvelope: Codable, Equatable, Sendable {
    static let fileName = "envelope.json"
    static let currentVersion = 2

    /// Where a capture came from.
    enum Source: String, Codable, Sendable {
        case shareMenu
        /// The Safari extension, which waits for a `CaptureResult`.
        case safari
    }

    enum Item: Codable, Equatable, Sendable {
        /// `name` is a file inside the envelope folder.
        case file(name: String, originalFilename: String?, resourceURL: URL?)
        case link(url: URL, title: String?)
        case text(String, sourceURL: URL?, title: String?)
    }

    var version = CaptureEnvelope.currentVersion
    var id: UUID
    var createdAt: Date
    var projectID: UUID
    var tags: [String]
    var note: String?
    var items: [Item]
    /// Nil for envelopes from before version 2, which came from the Share menu.
    var source: Source? = nil
    /// The page the files came from, such as the page an image was on.
    var pageURL: URL? = nil
    /// Instead of adding items, moves these References to `projectID` and
    /// adds `tags` and `note` to them. Used by Change… after a Safari save.
    var amends: [UUID]? = nil

    /// Converts envelope items back into captured items whose files live in `folder`.
    /// Returns nil for any file name that would escape the folder, and for a
    /// file that's a link to somewhere else.
    func capturedItems(in folder: URL) -> [CapturedItem?] {
        items.map { item in
            switch item {
            case .file(let name, let originalFilename, let resourceURL):
                guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
                let url = folder.appending(path: name, directoryHint: .notDirectory)
                guard !CaptureInboxStore.isLink(url) else { return nil }
                return .file(url: url, originalFilename: originalFilename, resourceURL: resourceURL)
            case .link(let url, let title):
                return .link(url: url, title: title)
            case .text(let text, let sourceURL, let title):
                return .text(text, sourceURL: sourceURL, title: title)
            }
        }
    }
}

/// Reads and writes envelopes in an inbox folder.
nonisolated struct CaptureInboxStore: Sendable {
    let inboxURL: URL

    /// Envelopes are a few kilobytes; anything bigger isn't one.
    static let maxEnvelopeBytes = 1_000_000

    /// True for a symbolic link. The extensions only ever write real files
    /// and folders, so a link in the inbox wasn't put there by them.
    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private var stagingURL: URL { inboxURL.appending(path: ".staging", directoryHint: .isDirectory) }

    /// A fresh, empty folder to collect a capture's files in.
    func makeStagingFolder() throws -> URL {
        let folder = stagingURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The staging folder for an upload that arrives in parts, named by its ID.
    func stagingFolder(for uploadID: UUID, creating: Bool) throws -> URL {
        let folder = stagingURL.appending(path: uploadID.uuidString, directoryHint: .isDirectory)
        if creating {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else if !FileManager.default.fileExists(atPath: folder.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        return folder
    }

    /// Writes the envelope into the staging folder and moves the folder into the inbox.
    func commit(_ envelope: CaptureEnvelope, stagingFolder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try data.write(to: stagingFolder.appending(path: CaptureEnvelope.fileName), options: .atomic)
        try FileManager.default.moveItem(
            at: stagingFolder,
            to: inboxURL.appending(path: envelope.id.uuidString, directoryHint: .isDirectory)
        )
    }

    /// Committed envelope folders, oldest first.
    func pendingFolders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { !Self.isLink($0) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
    }

    func readEnvelope(in folder: URL) throws -> CaptureEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = folder.appending(path: CaptureEnvelope.fileName)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? 0) <= Self.maxEnvelopeBytes
        else { throw CocoaError(.fileReadCorruptFile) }
        return try decoder.decode(CaptureEnvelope.self, from: Data(contentsOf: url))
    }

    /// Removes staging folders abandoned for more than a day.
    func removeStaleStagingFolders(now: Date = .now) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: stagingURL, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for folder in contents {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(created) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

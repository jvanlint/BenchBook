import Foundation

/// A message from the Safari extension's JavaScript, checked before anything
/// is written. Anything unexpected is refused rather than guessed at.
nonisolated enum SafariRequest: Equatable, Sendable {
    /// Projects, the last project used and tag names, for the panel.
    case state
    /// Starts a file upload, which then arrives in chunks.
    case begin
    case chunk(upload: UUID, data: Data)
    case save(SafariSave)
    /// Change… after a save: moves the saved References and adds tags and a note.
    case amend(referenceIDs: [UUID], projectID: UUID, tags: [String], note: String?)
    case cancel(upload: UUID)

    static let maxChunkBytes = 8 * 1024 * 1024
    static let maxTitleLength = 1_000
    static let maxNoteLength = 10_000
    static let maxTags = 50
    static let maxTagLength = 100
    static let maxReferenceIDs = 50

    init(message: Any?) throws {
        guard let message = message as? [String: Any], let action = message["action"] as? String else {
            throw SafariRequestError.invalid
        }
        switch action {
        case "state":
            self = .state
        case "begin":
            self = .begin
        case "chunk":
            guard let text = message["data"] as? String, text.utf8.count <= Self.maxChunkBytes * 4 / 3 + 4,
                  let data = Data(base64Encoded: text), !data.isEmpty
            else { throw SafariRequestError.invalid }
            self = .chunk(upload: try Self.uuid(message["upload"]), data: data)
        case "save":
            self = .save(try SafariSave(message: message))
        case "amend":
            guard let raw = message["referenceIDs"] as? [Any], !raw.isEmpty, raw.count <= Self.maxReferenceIDs else {
                throw SafariRequestError.invalid
            }
            self = .amend(
                referenceIDs: try raw.map(Self.uuid),
                projectID: try Self.uuid(message["projectID"]),
                tags: try Self.tags(message["tags"]),
                note: Self.text(message["note"], limit: Self.maxNoteLength)
            )
        case "cancel":
            self = .cancel(upload: try Self.uuid(message["upload"]))
        default:
            throw SafariRequestError.invalid
        }
    }

    static func uuid(_ value: Any?) throws -> UUID {
        guard let text = value as? String, let id = UUID(uuidString: text) else { throw SafariRequestError.invalid }
        return id
    }

    /// Trimmed text, cut to `limit` characters; nil when absent or blank.
    static func text(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    static func tags(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let raw = value as? [Any], raw.count <= maxTags else { throw SafariRequestError.invalid }
        return try raw.compactMap { item in
            guard let name = item as? String else { throw SafariRequestError.invalid }
            return text(name, limit: maxTagLength)
        }
    }

    /// Only web addresses: anything else (such as `file:` or `javascript:`) is refused.
    static func webURL(_ value: Any?) -> URL? {
        guard let text = value as? String, text.count <= 8_192, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil
        else { return nil }
        return url
    }
}

/// What to save from Safari.
nonisolated struct SafariSave: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case page(url: URL, title: String?)
        case text(String, pageURL: URL?, title: String?)
        /// A file uploaded in chunks: an image, or a PDF open in Safari.
        case file(upload: UUID, filename: String, resourceURL: URL?, pageURL: URL?)
    }

    var item: Item
    /// Nil saves to the last project used.
    var projectID: UUID?
    var tags: [String] = []
    var note: String?

    init(item: Item, projectID: UUID? = nil, tags: [String] = [], note: String? = nil) {
        self.item = item
        self.projectID = projectID
        self.tags = tags
        self.note = note
    }

    init(message: [String: Any]) throws {
        guard let item = message["item"] as? [String: Any], let kind = item["kind"] as? String else {
            throw SafariRequestError.invalid
        }
        let title = SafariRequest.text(item["title"], limit: SafariRequest.maxTitleLength)
        let pageURL = SafariRequest.webURL(item["pageURL"])
        switch kind {
        case "page":
            guard let url = SafariRequest.webURL(item["url"]) else { throw SafariRequestError.notAWebPage }
            self.item = .page(url: url, title: title)
        case "text":
            guard let text = SafariRequest.text(item["text"], limit: ReferenceLimits.maxTextLength) else {
                throw SafariRequestError.invalid
            }
            self.item = .text(text, pageURL: pageURL, title: title)
        case "file":
            let resourceURL = SafariRequest.webURL(item["url"])
            self.item = .file(
                upload: try SafariRequest.uuid(message["upload"]),
                filename: Self.safeFilename(item["filename"] as? String, fallback: resourceURL),
                resourceURL: resourceURL,
                pageURL: pageURL
            )
        default:
            throw SafariRequestError.invalid
        }
        projectID = try message["projectID"].map(SafariRequest.uuid)
        tags = try SafariRequest.tags(message["tags"])
        note = SafariRequest.text(message["note"], limit: SafariRequest.maxNoteLength)
    }

    /// A plain file name: no folders, no hidden files, nothing a file system
    /// would treat specially.
    static func safeFilename(_ name: String?, fallback url: URL?) -> String {
        let candidate = name ?? url?.lastPathComponent ?? ""
        let cleaned = candidate
            .split(whereSeparator: { "/\\:".contains($0) }).last.map(String.init) ?? ""
        let visible = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return visible.isEmpty ? "Download" : String(visible.prefix(200))
    }
}

nonisolated enum SafariRequestError: LocalizedError, Equatable {
    case invalid
    case notAWebPage
    case noProjects
    case uploadMissing
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalid:
            String(localized: "BenchBook didn't understand the request from Safari.")
        case .notAWebPage:
            String(localized: "Only web pages can be saved.")
        case .noProjects:
            String(localized: "There are no projects yet. Open BenchBook, make a project, then try again.")
        case .uploadMissing:
            String(localized: "The download didn't reach BenchBook. Try again.")
        case .tooLarge:
            String(localized: "The file is too large to save. Files can be up to 200 MB.")
        }
    }
}

/// Limits shared by the app and the extensions.
nonisolated enum ReferenceLimits {
    static let maxTextLength = 100_000
}

/// Answers the Safari extension: hands captures to BenchBook through the App
/// Group inbox, starts BenchBook if needed, and waits briefly for the result.
nonisolated struct SafariCaptureService {
    static let maxFileBytes: Int64 = 200 * 1024 * 1024
    private static let partName = "upload.part"

    let inbox: CaptureInboxStore
    let results: CaptureResultStore
    let directory: ProjectDirectory?
    var resultTimeout: Duration = .seconds(5)
    /// Starts BenchBook in the background, so it imports straight away.
    var launchApp: @Sendable () -> Void = {}

    /// The reply for the JavaScript: `ok` plus details, or `ok: false` and an `error`.
    func respond(to message: Any?) async -> [String: Any] {
        do {
            return try await handle(SafariRequest(message: message))
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    func handle(_ request: SafariRequest) async throws -> [String: Any] {
        switch request {
        case .state:
            let projects = directory?.load() ?? []
            var reply: [String: Any] = [
                "ok": true,
                "projects": projects.map { ["id": $0.id.uuidString, "name": $0.name, "detail": $0.detail] },
                "tags": directory?.loadTags() ?? [],
            ]
            if let id = lastProject(in: projects)?.id { reply["activeProjectID"] = id.uuidString }
            return reply

        case .begin:
            inbox.removeStaleStagingFolders()
            let upload = UUID()
            let folder = try inbox.stagingFolder(for: upload, creating: true)
            FileManager.default.createFile(atPath: folder.appending(path: Self.partName).path, contents: nil)
            return ["ok": true, "upload": upload.uuidString]

        case .chunk(let upload, let data):
            let folder = try uploadFolder(upload)
            let part = folder.appending(path: Self.partName)
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            guard size + Int64(data.count) <= Self.maxFileBytes else {
                try? FileManager.default.removeItem(at: folder)
                throw SafariRequestError.tooLarge
            }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return ["ok": true]

        case .cancel(let upload):
            if let folder = try? inbox.stagingFolder(for: upload, creating: false) {
                try? FileManager.default.removeItem(at: folder)
            }
            return ["ok": true]

        case .save(let save):
            return try await self.save(save)

        case .amend(let referenceIDs, let projectID, let tags, let note):
            let folder = try inbox.makeStagingFolder()
            let envelope = CaptureEnvelope(
                id: UUID(), createdAt: .now, projectID: projectID, tags: tags, note: note,
                items: [], source: .safari, amends: referenceIDs
            )
            return try await send(envelope, from: folder)
        }
    }

    private func save(_ save: SafariSave) async throws -> [String: Any] {
        let projects = directory?.load() ?? []
        guard let projectID = save.projectID ?? lastProject(in: projects)?.id else {
            if case .file(let upload, _, _, _) = save.item, let folder = try? uploadFolder(upload) {
                try? FileManager.default.removeItem(at: folder)
            }
            throw SafariRequestError.noProjects
        }

        let id: UUID
        let folder: URL
        let item: CaptureEnvelope.Item
        var pageURL: URL?
        switch save.item {
        case .page(let url, let title):
            id = UUID()
            folder = try inbox.makeStagingFolder()
            item = .link(url: url, title: title)
        case .text(let text, let page, let title):
            id = UUID()
            folder = try inbox.makeStagingFolder()
            item = .text(text, sourceURL: page, title: title)
        case .file(let upload, let filename, let resourceURL, let page):
            id = upload
            folder = try uploadFolder(upload)
            let part = folder.appending(path: Self.partName)
            guard let size = try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64, size > 0 else {
                try? FileManager.default.removeItem(at: folder)
                throw SafariRequestError.uploadMissing
            }
            // The envelope's own file can't be overwritten by a download's name.
            let name = filename == CaptureEnvelope.fileName ? "Download" : filename
            try FileManager.default.moveItem(at: part, to: folder.appending(path: name))
            item = .file(name: name, originalFilename: filename, resourceURL: resourceURL)
            pageURL = page
        }

        let envelope = CaptureEnvelope(
            id: id, createdAt: .now, projectID: projectID, tags: save.tags, note: save.note,
            items: [item], source: .safari, pageURL: pageURL
        )
        directory?.activeProjectID = projectID
        var reply = try await send(envelope, from: folder)
        if reply["projectName"] == nil, let name = projects.first(where: { $0.id == projectID })?.name {
            reply["projectName"] = name
        }
        return reply
    }

    /// Hands the envelope over, then waits for BenchBook's result. If none
    /// comes in time, the reply says it was sent and BenchBook reports later.
    private func send(_ envelope: CaptureEnvelope, from folder: URL) async throws -> [String: Any] {
        do {
            try inbox.commit(envelope, stagingFolder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        launchApp()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: resultTimeout)
        while clock.now < deadline {
            if let result = results.take(envelope.id) {
                var reply: [String: Any] = [
                    "ok": true,
                    "status": result.status.rawValue,
                    "referenceIDs": result.referenceIDs.map(\.uuidString),
                ]
                if let name = result.projectName { reply["projectName"] = name }
                if let message = result.message { reply["message"] = message }
                return reply
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ["ok": true, "status": "sent"]
    }

    private func uploadFolder(_ upload: UUID) throws -> URL {
        do {
            return try inbox.stagingFolder(for: upload, creating: false)
        } catch {
            throw SafariRequestError.uploadMissing
        }
    }

    /// The project last used in BenchBook or Safari, or the first one.
    private func lastProject(in projects: [ProjectSummary]) -> ProjectSummary? {
        let active = directory?.activeProjectID
        return projects.first { $0.id == active } ?? projects.first
    }
}

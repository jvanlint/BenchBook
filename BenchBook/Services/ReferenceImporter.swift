import Foundation
import SwiftData

/// The result of importing one captured item.
enum CaptureOutcome {
    case added(Reference)
    /// The same file is already in this Project.
    case duplicate(existing: Reference, item: CapturedItem)
    case failed(item: CapturedItem, error: Error)
}

/// The single import path for drops, pastes, file panels and the Share
/// extension. Each item is validated, its file copied into the library, and
/// its Reference saved, before it counts as added.
struct ReferenceImporter {
    static let maxTextLength = 100_000

    let context: ModelContext
    let library: AssetLibrary

    func importItems(
        _ items: [CapturedItem],
        into project: Project,
        tags: [String] = [],
        note: String? = nil
    ) async -> [CaptureOutcome] {
        var outcomes: [CaptureOutcome] = []
        for item in items {
            do {
                outcomes.append(try await importItem(item, into: project, tags: tags, note: note))
            } catch {
                outcomes.append(.failed(item: item, error: error))
            }
        }
        return outcomes
    }

    private func importItem(_ item: CapturedItem, into project: Project, tags: [String], note: String?) async throws -> CaptureOutcome {
        switch item {
        case .file(let url, let originalFilename, let resourceURL):
            return try await importFile(url, originalFilename: originalFilename, resourceURL: resourceURL,
                                        item: item, project: project, tags: tags, note: note)

        case .link(let url, let title):
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
                throw CaptureError.invalidLink(url.absoluteString)
            }
            let video = VideoLink.parse(url)
            let reference = Reference(
                project: project,
                kind: video == nil ? .webpage : .videoLink,
                title: title?.trimmedOrNil,
                note: note?.trimmedOrNil,
                sourcePageURL: url
            )
            context.insert(reference)
            if let start = video?.startSeconds {
                context.insert(VideoMoment(reference: reference, offsetSeconds: start))
            }
            try saveReference(reference, tags: tags)
            return .added(reference)

        case .text(let text, let sourceURL, let title):
            guard let trimmed = text.trimmedOrNil else { throw CaptureError.emptyText }
            let reference = Reference(
                project: project,
                kind: .textSnippet,
                title: title?.trimmedOrNil,
                note: note?.trimmedOrNil,
                text: String(trimmed.prefix(Self.maxTextLength)),
                sourcePageURL: sourceURL
            )
            context.insert(reference)
            try saveReference(reference, tags: tags)
            return .added(reference)
        }
    }

    private func importFile(
        _ url: URL, originalFilename: String?, resourceURL: URL?,
        item: CapturedItem, project: Project, tags: [String], note: String?
    ) async throws -> CaptureOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let inspected = try await Task.detached(priority: .userInitiated) {
            try FileInspector.inspect(url)
        }.value

        if let existing = project.references.first(where: { $0.asset?.sha256 == inspected.sha256 }) {
            return .duplicate(existing: existing, item: item)
        }

        let assetID = UUID()
        let relativePath = AssetLibrary.originalRelativePath(assetID: assetID, fileExtension: inspected.fileExtension)
        let library = library
        try await Task.detached(priority: .userInitiated) {
            try library.copyOriginal(from: url, toRelativePath: relativePath)
        }.value

        let asset = ManagedAsset(
            id: assetID,
            originalRelativePath: relativePath,
            originalFilename: originalFilename?.trimmedOrNil,
            mimeType: inspected.mimeType,
            byteCount: inspected.byteCount,
            sha256: inspected.sha256,
            pixelWidth: inspected.pixelWidth,
            pixelHeight: inspected.pixelHeight
        )
        let reference = Reference(
            project: project,
            kind: inspected.kind,
            note: note?.trimmedOrNil,
            originalResourceURL: resourceURL
        )
        context.insert(asset)
        context.insert(reference)
        reference.asset = asset

        do {
            try saveReference(reference, tags: tags)
        } catch {
            library.removeFiles(assetID: assetID, originalRelativePath: relativePath)
            throw error
        }
        return .added(reference)
    }

    /// Adds tags and saves. On failure the unsaved Reference is discarded.
    private func saveReference(_ reference: Reference, tags: [String]) throws {
        do {
            try ReferenceService(context: context, library: library).setTags(tags, on: reference)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

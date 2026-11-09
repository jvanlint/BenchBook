import Foundation
import SwiftData

/// Moves or copies References to another Project.
struct ReferenceTransfer {
    enum Mode {
        case move, copy
    }

    struct Result: Equatable {
        /// The moved References, or the new copies.
        var transferred: [Reference] = []
        /// Files the target Project already has, left where they were.
        var duplicates: [Reference] = []
    }

    let context: ModelContext
    let library: AssetLibrary

    /// A copy keeps everything: title, note, tags, image notes, video
    /// moments and link details. It shares the original's stored file
    /// rather than duplicating it on disk.
    @discardableResult
    func transfer(_ references: [Reference], to project: Project, mode: Mode) throws -> Result {
        var result = Result()
        var targetHashes = Set(project.references.compactMap(\.asset?.sha256))
        var posters: [(from: URL, to: URL)] = []

        for reference in references where reference.project?.id != project.id {
            // Same rule as capture: a Project holds each file once.
            if let hash = reference.asset?.sha256 {
                guard !targetHashes.contains(hash) else {
                    result.duplicates.append(reference)
                    continue
                }
                targetHashes.insert(hash)
            }
            switch mode {
            case .move:
                reference.project = project
                reference.updatedAt = .now
                result.transferred.append(reference)
            case .copy:
                let copy = makeCopy(of: reference, in: project)
                posters.append((library.posterURL(referenceID: reference.id), library.posterURL(referenceID: copy.id)))
                result.transferred.append(copy)
            }
        }
        guard !result.transferred.isEmpty else { return result }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        // Posters are named by Reference, so each copy gets its own.
        for poster in posters where FileManager.default.fileExists(atPath: poster.from.path) {
            try? FileManager.default.copyItem(at: poster.from, to: poster.to)
        }
        return result
    }

    private func makeCopy(of original: Reference, in project: Project) -> Reference {
        let copy = Reference(
            project: project,
            kind: original.kind ?? .note,
            title: original.title,
            note: original.note,
            text: original.text,
            sourcePageURL: original.sourcePageURL,
            originalResourceURL: original.originalResourceURL,
            capturedAt: original.capturedAt
        )
        copy.kindRaw = original.kindRaw  // keeps kinds this version doesn't know
        copy.updatedAt = .now
        copy.videoChannel = original.videoChannel
        copy.videoChannelURL = original.videoChannelURL
        copy.videoDurationSeconds = original.videoDurationSeconds
        copy.videoPublishedAt = original.videoPublishedAt
        copy.videoDescription = original.videoDescription
        copy.videoInfoFetchedAt = original.videoInfoFetchedAt
        copy.linkSiteName = original.linkSiteName
        copy.linkDescription = original.linkDescription
        copy.linkPreviewFetchedAt = original.linkPreviewFetchedAt
        context.insert(copy)
        copy.asset = original.asset

        for link in original.tagLinks {
            if let tag = link.tag { context.insert(ReferenceTag(reference: copy, tag: tag)) }
        }
        for moment in original.videoMoments {
            context.insert(VideoMoment(
                reference: copy, offsetSeconds: moment.offsetSeconds,
                title: moment.title, note: moment.note, createdAt: moment.createdAt
            ))
        }
        for note in original.imageNotes {
            context.insert(ImageNote(
                reference: copy, x: note.x, y: note.y, width: note.width, height: note.height,
                text: note.text, createdAt: note.createdAt
            ))
        }
        return copy
    }
}

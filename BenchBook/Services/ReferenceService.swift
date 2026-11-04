import Foundation
import SwiftData

/// Owns Reference edits, tags and deletion, including cleanup of stored files.
struct ReferenceService {
    let context: ModelContext
    let library: AssetLibrary

    func updateDetails(_ reference: Reference, title: String, note: String, tagsText: String) throws {
        reference.title = title.trimmedOrNil
        reference.note = note.trimmedOrNil
        try setTags(TagNames.parse(tagsText), on: reference)
        reference.updatedAt = .now
        try save()
    }

    /// Adds a note the user wrote to `project`. Needs a title or some text.
    @discardableResult
    func createNote(in project: Project, title: String, text: String, tagsText: String) throws -> Reference {
        guard title.trimmedOrNil != nil || text.trimmedOrNil != nil else { throw NoteError.empty }
        let reference = Reference(project: project, kind: .note)
        context.insert(reference)
        try fillNote(reference, title: title, text: text, tagsText: tagsText)
        return reference
    }

    func updateNote(_ reference: Reference, title: String, text: String, tagsText: String) throws {
        guard title.trimmedOrNil != nil || text.trimmedOrNil != nil else { throw NoteError.empty }
        try fillNote(reference, title: title, text: text, tagsText: tagsText)
    }

    private func fillNote(_ reference: Reference, title: String, text: String, tagsText: String) throws {
        reference.title = title.trimmedOrNil
        // Keep the writer's line breaks and indentation; only trim the ends.
        reference.text = text.trimmedOrNil.map { String($0.prefix(ReferenceImporter.maxTextLength)) }
        reference.updatedAt = .now
        do {
            try setTags(TagNames.parse(tagsText), on: reference)
        } catch {
            context.rollback()
            throw error
        }
        try save()
    }

    /// Replaces the Reference's tags, reusing library Tags by normalized name.
    /// Does not save.
    func setTags(_ names: [String], on reference: Reference) throws {
        let wanted = Dictionary(names.map { (TagNames.normalize($0), $0) }, uniquingKeysWith: { first, _ in first })

        for link in reference.tagLinks where !wanted.keys.contains(link.tag?.normalizedName ?? "") {
            context.delete(link)
        }
        let existing = Set(reference.tagLinks.compactMap { $0.tag?.normalizedName })
        let missing = wanted.filter { !existing.contains($0.key) }
        guard !missing.isEmpty else { return }

        let normalizedNames = Array(missing.keys)
        let found = try context.fetch(FetchDescriptor<Tag>(
            predicate: #Predicate { normalizedNames.contains($0.normalizedName) }
        ))
        var tagsByName = Dictionary(found.map { ($0.normalizedName, $0) }, uniquingKeysWith: { first, _ in first })

        for (normalized, name) in missing.sorted(by: { $0.key < $1.key }) {
            let tag = tagsByName[normalized] ?? {
                let tag = Tag(name: name, normalizedName: normalized)
                context.insert(tag)
                tagsByName[normalized] = tag
                return tag
            }()
            context.insert(ReferenceTag(reference: reference, tag: tag))
        }
    }

    /// Deletes the Reference, then its stored file if nothing else uses it.
    func delete(_ reference: Reference) throws {
        let asset = reference.asset
        let posterURL = library.videoPosterURL(referenceID: reference.id)
        context.delete(reference)
        try save()
        try? FileManager.default.removeItem(at: posterURL)
        if let asset {
            try removeIfUnused(asset)
        }
    }

    /// Removes leftovers from interrupted imports or deletes: assets with no
    /// References, files in the library with no asset record, and posters
    /// of deleted video links (e.g. from deleting a whole Project).
    func reconcileLibrary() throws {
        for asset in try context.fetch(FetchDescriptor<ManagedAsset>()) where asset.references.isEmpty {
            try removeIfUnused(asset)
        }
        let knownIDs = Set(try context.fetch(FetchDescriptor<ManagedAsset>()).map(\.id))
        for file in library.orphanedFiles(knownAssetIDs: knownIDs) {
            try? FileManager.default.removeItem(at: file)
        }
        let referenceIDs = Set(try context.fetch(FetchDescriptor<Reference>()).map(\.id))
        for file in library.orphanedPosters(knownReferenceIDs: referenceIDs) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeIfUnused(_ asset: ManagedAsset) throws {
        guard asset.references.isEmpty else { return }
        let id = asset.id
        let path = asset.originalRelativePath
        context.delete(asset)
        try save()
        library.removeFiles(assetID: id, originalRelativePath: path)
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum NoteError: LocalizedError, Equatable {
    case empty

    var errorDescription: String? {
        String(localized: "Write a title or some text for the note.")
    }
}

extension String {
    nonisolated var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

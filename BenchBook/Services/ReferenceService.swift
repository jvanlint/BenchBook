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
        context.delete(reference)
        try save()
        if let asset {
            try removeIfUnused(asset)
        }
    }

    /// Removes leftovers from interrupted imports or deletes: assets with no
    /// References, and files in the library with no asset record.
    func reconcileLibrary() throws {
        for asset in try context.fetch(FetchDescriptor<ManagedAsset>()) where asset.references.isEmpty {
            try removeIfUnused(asset)
        }
        let knownIDs = Set(try context.fetch(FetchDescriptor<ManagedAsset>()).map(\.id))
        for file in library.orphanedFiles(knownAssetIDs: knownIDs) {
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

extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

import Foundation

/// What the References grid shows. View state only; never persisted.
///
/// A Reference matches when it has the chosen type (if any) and every
/// selected tag, so each extra tag narrows the results.
struct ReferenceFilter: Equatable {
    var kind: ReferenceKind?
    /// Normalized tag names.
    var tags: Set<String> = []

    var isActive: Bool {
        kind != nil || !tags.isEmpty
    }

    func matches(_ reference: Reference) -> Bool {
        if let kind, reference.kind != kind {
            return false
        }
        guard !tags.isEmpty else { return true }
        let referenceTags = Set(reference.tagLinks.compactMap { $0.tag?.normalizedName })
        return tags.isSubset(of: referenceTags)
    }

    mutating func toggle(tag normalizedName: String) {
        if tags.contains(normalizedName) {
            tags.remove(normalizedName)
        } else {
            tags.insert(normalizedName)
        }
    }

    /// Drops selections that no longer exist in the Project, e.g. after a
    /// tag is removed from its last Reference.
    mutating func prune(availableKinds: Set<ReferenceKind>, availableTags: Set<String>) {
        if let kind, !availableKinds.contains(kind) {
            self.kind = nil
        }
        tags.formIntersection(availableTags)
    }
}

/// A tag used in a Project, with how many References carry it.
struct TagUsage: Identifiable, Equatable {
    var normalizedName: String
    var name: String
    var count: Int
    var colorName: String? = nil

    var id: String { normalizedName }

    /// Every tag on `references`, most used first, then by name.
    static func summarize(_ references: [Reference]) -> [TagUsage] {
        var usage: [String: TagUsage] = [:]
        for reference in references {
            for tag in reference.tags {
                usage[tag.normalizedName, default: TagUsage(
                    normalizedName: tag.normalizedName, name: tag.name, count: 0, colorName: tag.colorName
                )].count += 1
            }
        }
        return usage.values.sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

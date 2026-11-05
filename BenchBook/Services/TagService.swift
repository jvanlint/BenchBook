import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The colours a tag can have. Stored by name, so they follow the system's
/// light and dark appearance.
enum TagColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var displayName: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .mint: String(localized: "Mint")
        case .teal: String(localized: "Teal")
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .brown: String(localized: "Brown")
        case .gray: String(localized: "Gray")
        }
    }
}

extension Tag {
    var tagColor: TagColor? {
        colorName.flatMap(TagColor.init(rawValue:))
    }

    /// The tag's colour, or the app's accent colour when it has none.
    var displayColor: Color {
        tagColor?.color ?? .accentColor
    }

    /// How many References carry this tag.
    var usageCount: Int { referenceLinks.count }

    var references: [Reference] { referenceLinks.compactMap(\.reference) }

    /// Projects with a Reference carrying this tag, sorted.
    var projectNames: [String] {
        Set(references.compactMap { $0.project?.name })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Most used first, then by name.
    static func byUsage(_ lhs: Tag, _ rhs: Tag) -> Bool {
        lhs.usageCount != rhs.usageCount
            ? lhs.usageCount > rhs.usageCount
            : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Whether a tag is on all, some or none of a set of References.
enum TagState {
    case all, some, none
}

enum TagError: LocalizedError, Equatable {
    case emptyName

    var errorDescription: String? {
        String(localized: "A tag needs a name.")
    }
}

/// Owns library-wide tag changes: renaming, merging, colours, deleting,
/// and adding or removing a tag on many References at once.
struct TagService {
    let context: ModelContext

    // MARK: Finding

    /// The tag with this name, ignoring case and spacing, if one exists.
    func existingTag(named name: String) throws -> Tag? {
        let normalized = TagNames.normalize(name)
        return try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.normalizedName == normalized })).first
    }

    /// The tag with this name, created if needed. Does not save.
    func tag(named name: String) throws -> Tag {
        let cleaned = TagNames.parse(name).first ?? ""
        guard !cleaned.isEmpty else { throw TagError.emptyName }
        if let existing = try existingTag(named: cleaned) { return existing }
        let tag = Tag(name: cleaned, normalizedName: TagNames.normalize(cleaned))
        context.insert(tag)
        return tag
    }

    /// Creates an unused tag, e.g. to drag onto references later.
    @discardableResult
    func createTag(named name: String) throws -> Tag {
        let tag = try tag(named: name)
        try save()
        return tag
    }

    // MARK: Library-wide changes

    /// Renames the tag. If another tag already has the new name, the two
    /// are merged into that one, which takes the new spelling.
    @discardableResult
    func rename(_ tag: Tag, to newName: String) throws -> Tag {
        guard let cleaned = TagNames.parse(newName).first else { throw TagError.emptyName }
        if let existing = try existingTag(named: cleaned), existing.id != tag.id {
            existing.name = cleaned
            try merge([tag], into: existing)
            return existing
        }
        tag.name = cleaned
        tag.normalizedName = TagNames.normalize(cleaned)
        tag.updatedAt = .now
        try save()
        return tag
    }

    /// Moves every Reference from `tags` onto `target`, then deletes them.
    /// The target keeps its colour, or takes the first one it finds.
    func merge(_ tags: [Tag], into target: Tag) throws {
        for source in tags where source.id != target.id {
            for link in Array(source.referenceLinks) {
                if let reference = link.reference, !has(target, reference) {
                    context.insert(ReferenceTag(reference: reference, tag: target))
                    reference.updatedAt = .now
                }
                context.delete(link)
            }
            if target.colorName == nil { target.colorName = source.colorName }
            context.delete(source)
        }
        target.updatedAt = .now
        try save()
    }

    /// Deletes tags and removes them from every Reference. References stay.
    func delete(_ tags: [Tag]) throws {
        for tag in tags {
            for reference in tag.references { reference.updatedAt = .now }
            context.delete(tag)
        }
        try save()
    }

    func setColor(_ color: TagColor?, for tags: [Tag]) throws {
        for tag in tags {
            tag.colorName = color?.rawValue
            tag.updatedAt = .now
        }
        try save()
    }

    /// Deletes tags no Reference uses. Returns how many were removed.
    @discardableResult
    func removeUnused() throws -> Int {
        let unused = try context.fetch(FetchDescriptor<Tag>()).filter { $0.referenceLinks.isEmpty }
        for tag in unused { context.delete(tag) }
        try save()
        return unused.count
    }

    // MARK: Tagging References

    func state(of tag: Tag, on references: [Reference]) -> TagState {
        let count = references.filter { has(tag, $0) }.count
        return count == 0 ? .none : count == references.count ? .all : .some
    }

    /// Adds the tag to every Reference that doesn't have it.
    func add(_ tag: Tag, to references: [Reference]) throws {
        for reference in references where !has(tag, reference) {
            context.insert(ReferenceTag(reference: reference, tag: tag))
            reference.updatedAt = .now
        }
        try save()
    }

    /// Adds tags by name (comma-separated text allowed), creating new ones.
    func addTags(named text: String, to references: [Reference]) throws {
        for name in TagNames.parse(text) {
            let tag = try tag(named: name)
            for reference in references where !has(tag, reference) {
                context.insert(ReferenceTag(reference: reference, tag: tag))
                reference.updatedAt = .now
            }
        }
        try save()
    }

    func remove(_ tag: Tag, from references: [Reference]) throws {
        let ids = Set(references.map(\.id))
        for link in Array(tag.referenceLinks) {
            if let reference = link.reference, ids.contains(reference.id) {
                context.delete(link)
                reference.updatedAt = .now
            }
        }
        try save()
    }

    /// Removes the tag if every Reference has it; otherwise adds it to all.
    func toggle(_ tag: Tag, on references: [Reference]) throws {
        if state(of: tag, on: references) == .all {
            try remove(tag, from: references)
        } else {
            try add(tag, to: references)
        }
    }

    private func has(_ tag: Tag, _ reference: Reference) -> Bool {
        reference.tagLinks.contains { $0.tag?.id == tag.id }
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

// MARK: - Dragging tags and References inside BenchBook

extension UTType {
    /// Declared in Info.plist. Private to BenchBook, so a dragged tag is
    /// never mistaken for text to capture.
    nonisolated static let benchBookTag = UTType(exportedAs: "com.jasonvanlint.benchbook.tag")
    nonisolated static let benchBookReferences = UTType(exportedAs: "com.jasonvanlint.benchbook.references")
}

/// A tag being dragged from the sidebar.
nonisolated struct TagDragItem: Codable, Transferable {
    let tagID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .benchBookTag)
    }
}

/// References being dragged from the grid.
nonisolated struct ReferencesDragItem: Codable, Transferable {
    let referenceIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .benchBookReferences)
    }
}

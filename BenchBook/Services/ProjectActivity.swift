import Foundation
import SwiftData

extension ModelContext {
    /// Marks each project with unsaved changes, to itself or anything in it,
    /// as updated now. Services call this before saving the user's own edits,
    /// so a project's `updatedAt` is when the user last worked on it.
    ///
    /// Background work, such as fetching link details or suggesting tags,
    /// doesn't call it, and nor do changes to the library as a whole, such as
    /// renaming a tag.
    func touchEditedProjects(now: Date = .now) {
        var edited: [PersistentIdentifier: Project] = [:]
        for model in insertedModelsArray + changedModelsArray + deletedModelsArray {
            if let project = Self.project(of: model), !project.isDeleted {
                edited[project.persistentModelID] = project
            }
        }
        // A new project keeps the same created and updated dates.
        for case let project as Project in insertedModelsArray {
            edited[project.persistentModelID] = nil
        }
        for project in edited.values {
            project.updatedAt = now
        }
    }

    /// The project a record belongs to, if it belongs to one.
    private static func project(of model: any PersistentModel) -> Project? {
        switch model {
        case let project as Project: project
        case let reference as Reference: reference.project
        case let moment as VideoMoment: moment.reference?.project
        case let link as ReferenceTag: link.reference?.project
        case let markup as Markup: markup.reference?.project ?? markup.buildPhoto?.project
        case let paint as ProjectPaint: paint.project
        case let item as AftermarketItem: item.project
        case let photo as BuildPhoto: photo.project
        case let link as BuildPhotoTag: link.photo?.project
        default: nil
        }
    }
}

/// How the sidebar lists projects.
nonisolated enum ProjectSort: String, CaseIterable, Identifiable, Sendable {
    /// A to Z, as Finder sorts names.
    case name
    /// Newest first.
    case dateCreated
    /// Most recently worked on first.
    case lastUpdated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: String(localized: "Name")
        case .dateCreated: String(localized: "Date Created")
        case .lastUpdated: String(localized: "Last Updated")
        }
    }

    /// Ties, such as two projects with the same date, fall back to name.
    func sorted(_ projects: [Project]) -> [Project] {
        projects.sorted { lhs, rhs in
            switch self {
            case .dateCreated where lhs.createdAt != rhs.createdAt:
                return lhs.createdAt > rhs.createdAt
            case .lastUpdated where lhs.updatedAt != rhs.updatedAt:
                return lhs.updatedAt > rhs.updatedAt
            default:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

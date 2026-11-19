import Foundation
import SwiftData

/// Editable copy of a Project's fields. Forms edit a draft, so nothing touches
/// the store until the user saves.
struct ProjectDraft: Equatable {
    var name = ""
    var subject = ""
    var markingsScheme = ""
    var notes = ""
    var status = ProjectStatus.researching

    init() {}

    init(project: Project) {
        name = project.name
        subject = project.subject
        markingsScheme = project.markingsScheme ?? ""
        notes = project.notes ?? ""
        status = project.status
    }

    var hasValidName: Bool {
        !name.trimmed.isEmpty
    }
}

enum ProjectServiceError: LocalizedError {
    case blankName

    var errorDescription: String? {
        switch self {
        case .blankName:
            "A project needs a name."
        }
    }
}

/// Owns Project validation and saves, so views don't duplicate these rules.
struct ProjectService {
    let context: ModelContext

    /// A new project using `kits` from the catalogue. A kit in another
    /// project moves to this one.
    @discardableResult
    func createProject(from draft: ProjectDraft, kits: [Kit] = []) throws -> Project {
        guard draft.hasValidName else { throw ProjectServiceError.blankName }

        let project = Project(name: draft.name.trimmed)
        apply(draft, to: project)
        context.insert(project)
        for kit in kits {
            if let previous = kit.project { previous.updatedAt = .now }
            kit.project = project
            kit.follow(project.status)
        }
        try save()
        return project
    }

    func update(_ project: Project, from draft: ProjectDraft) throws {
        guard draft.hasValidName else { throw ProjectServiceError.blankName }
        guard draft != ProjectDraft(project: project) else { return }

        let statusChanged = draft.status != project.status
        apply(draft, to: project)
        if statusChanged { kitsFollow(project) }
        project.updatedAt = .now
        try save()
    }

    func setStatus(_ status: ProjectStatus, for project: Project) throws {
        guard project.statusRaw != status.rawValue else { return }
        project.statusRaw = status.rawValue
        kitsFollow(project)
        project.updatedAt = .now
        try save()
    }

    /// In Progress makes the project's BNIB and Opened kits WIP; Completed
    /// makes its kits Built (`Kit.follow`).
    private func kitsFollow(_ project: Project) {
        for kit in project.kits { kit.follow(project.status) }
    }

    /// Deletes the project with its references, image notes, paint list and
    /// aftermarket parts, then any stored files nothing else uses. Catalogue
    /// paints, ownership and tags are kept.
    func delete(_ project: Project, library: AssetLibrary) throws {
        let assets = project.references.compactMap(\.asset) + project.aftermarketItems.compactMap(\.imageAsset)
            + project.buildPhotos.compactMap(\.asset)
        let posters = project.references.map { library.posterURL(referenceID: $0.id) }
        context.delete(project)
        try save()

        for poster in posters {
            try? FileManager.default.removeItem(at: poster)
        }
        let references = ReferenceService(context: context, library: library)
        let unique = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for asset in unique.values {
            try references.removeAssetIfUnused(asset)
        }
    }

    private func apply(_ draft: ProjectDraft, to project: Project) {
        project.name = draft.name.trimmed
        project.subject = draft.subject.trimmed
        project.markingsScheme = draft.markingsScheme.trimmedOrNil
        project.notes = draft.notes.trimmedOrNil
        project.statusRaw = draft.status.rawValue
    }

    /// Saves explicitly at the end of each workflow. On failure, unsaved
    /// changes are discarded so the UI never shows edits that aren't stored.
    private func save() throws {
        do {
            context.touchEditedProjects()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

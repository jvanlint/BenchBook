import Foundation
import SwiftData

/// Editable copy of a Project's fields. Forms edit a draft, so nothing touches
/// the store until the user saves.
struct ProjectDraft: Equatable {
    var name = ""
    var manufacturer = ""
    var subject = ""
    var scale = ""
    var kitNumber = ""
    var markingsScheme = ""
    var notes = ""

    init() {}

    init(project: Project) {
        name = project.name
        manufacturer = project.manufacturer
        subject = project.subject
        scale = project.scale
        kitNumber = project.kitNumber ?? ""
        markingsScheme = project.markingsScheme ?? ""
        notes = project.notes ?? ""
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

    @discardableResult
    func createProject(from draft: ProjectDraft) throws -> Project {
        guard draft.hasValidName else { throw ProjectServiceError.blankName }

        let project = Project(name: draft.name.trimmed)
        apply(draft, to: project)
        context.insert(project)
        try save()
        return project
    }

    func update(_ project: Project, from draft: ProjectDraft) throws {
        guard draft.hasValidName else { throw ProjectServiceError.blankName }
        guard draft != ProjectDraft(project: project) else { return }

        apply(draft, to: project)
        project.updatedAt = .now
        try save()
    }

    private func apply(_ draft: ProjectDraft, to project: Project) {
        project.name = draft.name.trimmed
        project.manufacturer = draft.manufacturer.trimmed
        project.subject = draft.subject.trimmed
        project.scale = draft.scale.trimmed
        project.kitNumber = draft.kitNumber.trimmedOrNil
        project.markingsScheme = draft.markingsScheme.trimmedOrNil
        project.notes = draft.notes.trimmedOrNil
    }

    /// Saves explicitly at the end of each workflow. On failure, unsaved
    /// changes are discarded so the UI never shows edits that aren't stored.
    private func save() throws {
        do {
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

    /// Blank optional text is stored as nil.
    var trimmedOrNil: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}

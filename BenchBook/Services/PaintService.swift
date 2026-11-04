import Foundation
import SwiftData

/// Editable copy of a Paint's fields, used by the editor and CSV import.
struct PaintDraft: Equatable {
    var brand = ""
    var range = ""
    var code = ""
    var name = ""
    /// e.g. "FS 36270" or "RLM 76".
    var standardCode = ""
    var notes = ""
    /// "#RRGGBB" or nil for no swatch.
    var swatchHex: String?
    var isOwned = false

    init() {}

    init(paint: Paint) {
        brand = paint.brand
        range = paint.range
        code = paint.code
        name = paint.name
        standardCode = paint.standardCode
        notes = paint.notes ?? ""
        swatchHex = paint.swatchHex
        isOwned = paint.isOwned
    }

    var identityKey: String {
        PaintIdentity.key(brand: brand, range: range, code: code)
    }

    /// Brand and code are required; everything else is optional.
    var missingRequiredField: Bool {
        brand.trimmedOrNil == nil || code.trimmedOrNil == nil
    }
}

enum PaintServiceError: LocalizedError, Equatable {
    case missingBrandOrCode
    case duplicate(String)
    case inUse(paint: String, projects: [String])

    var errorDescription: String? {
        switch self {
        case .missingBrandOrCode:
            String(localized: "A paint needs a brand and a code.")
        case .duplicate(let name):
            String(localized: "“\(name)” is already in your catalogue.")
        case .inUse(let paint, let projects):
            String(localized: "“\(paint)” is used in \(projects.formatted(.list(type: .and))). Remove it from those projects first.")
        }
    }
}

/// Owns the paint catalogue, ownership and the paints chosen for Projects.
struct PaintService {
    let context: ModelContext

    // MARK: Catalogue

    @discardableResult
    func createPaint(from draft: PaintDraft) throws -> Paint {
        try validate(draft, excluding: nil)
        let paint = Paint(brand: "", code: "", identityKey: draft.identityKey)
        context.insert(paint)
        apply(draft, to: paint)
        try save()
        return paint
    }

    func update(_ paint: Paint, from draft: PaintDraft) throws {
        try validate(draft, excluding: paint)
        guard draft != PaintDraft(paint: paint) else { return }
        apply(draft, to: paint)
        paint.updatedAt = .now
        try save()
    }

    /// Refuses while any Project uses the paint.
    func delete(_ paint: Paint) throws {
        let projects = paint.projectNames
        guard projects.isEmpty else {
            throw PaintServiceError.inUse(paint: paint.displayName, projects: projects)
        }
        context.delete(paint)
        try save()
    }

    func setOwned(_ owned: Bool, for paint: Paint) throws {
        try applyOwnership(owned, to: paint)
        try save()
    }

    /// An existing paint with the same brand, range and code, if any.
    func existingPaint(identityKey: String) throws -> Paint? {
        try context.fetch(FetchDescriptor<Paint>(predicate: #Predicate { $0.identityKey == identityKey })).first
    }

    // MARK: Projects

    /// Adds paints not already in the Project. Returns how many were added.
    @discardableResult
    func add(_ paints: [Paint], to project: Project) throws -> Int {
        let existing = Set(project.paintRequirements.compactMap { $0.selectedPaint?.id })
        let new = paints.filter { !existing.contains($0.id) }
        for paint in new {
            context.insert(ProjectPaint(project: project, paint: paint))
        }
        try save()
        return new.count
    }

    func remove(_ projectPaint: ProjectPaint) throws {
        context.delete(projectPaint)
        try save()
    }

    /// Updates "used for" without saving; call `commit()` when editing ends.
    func setUsedFor(_ text: String, on projectPaint: ProjectPaint) {
        let value = text.isEmpty ? nil : text
        guard projectPaint.usedFor != value else { return }
        projectPaint.usedFor = value
        projectPaint.updatedAt = .now
    }

    func commit() throws {
        guard context.hasChanges else { return }
        try save()
    }

    // MARK: Helpers

    func validate(_ draft: PaintDraft, excluding paint: Paint?) throws {
        guard !draft.missingRequiredField else { throw PaintServiceError.missingBrandOrCode }
        if let existing = try existingPaint(identityKey: draft.identityKey), existing.id != paint?.id {
            throw PaintServiceError.duplicate(existing.displayName)
        }
    }

    /// Copies the draft into the paint without saving. Used by CSV import too.
    func apply(_ draft: PaintDraft, to paint: Paint) {
        paint.brand = draft.brand.trimmedOrNil ?? ""
        paint.range = draft.range.trimmedOrNil ?? ""
        paint.code = draft.code.trimmedOrNil ?? ""
        paint.name = draft.name.trimmedOrNil ?? ""
        paint.standardCode = draft.standardCode.trimmedOrNil ?? ""
        paint.notes = draft.notes.trimmedOrNil
        paint.swatchHex = draft.swatchHex.flatMap(SwatchColor.normalized)
        paint.identityKey = draft.identityKey
        try? applyOwnership(draft.isOwned, to: paint)
    }

    private func applyOwnership(_ owned: Bool, to paint: Paint) throws {
        if owned, paint.ownership == nil {
            context.insert(OwnedPaint(paint: paint))
        } else if !owned, let ownership = paint.ownership {
            paint.ownership = nil
            context.delete(ownership)
        }
    }

    func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension Project {
    /// The Project's paints, by brand then code.
    var sortedPaintRequirements: [ProjectPaint] {
        paintRequirements.sorted {
            let a = $0.selectedPaint, b = $1.selectedPaint
            let brand = (a?.brand ?? "").localizedStandardCompare(b?.brand ?? "")
            if brand != .orderedSame { return brand == .orderedAscending }
            return (a?.code ?? "").localizedStandardCompare(b?.code ?? "") == .orderedAscending
        }
    }
}

import Foundation
import SwiftData

/// One line of a mix's recipe in the editor.
struct MixPartDraft: Equatable, Identifiable {
    var paintID: UUID
    /// More than zero.
    var parts: Double = 1

    var id: UUID { paintID }
}

/// Editable copy of a Paint's fields, used by the editor and CSV import.
struct PaintDraft: Equatable {
    var isMix = false
    /// A mix's recipe, in order.
    var recipe: [MixPartDraft] = []
    var brand = ""
    var range = ""
    var code = ""
    var name = ""
    /// Nil for no standard. Then the code and match are ignored.
    var standardSystem: PaintStandardSystem?
    /// e.g. "36270" for FS 595, or "FS 36375 / BS 637" for Multiple.
    var standardCode = ""
    var match: PaintMatch?
    var type: PaintType?
    var notes = ""
    /// "#RRGGBB" or nil for no swatch.
    var swatchHex: String?
    var isOwned = false

    init() {}

    init(paint: Paint) {
        isMix = paint.isMix
        recipe = paint.sortedRecipe.compactMap { part in
            part.paint.map { MixPartDraft(paintID: $0.id, parts: part.parts) }
        }
        brand = paint.brand
        range = paint.range
        code = paint.code
        name = paint.name
        standardSystem = paint.standard?.system
        standardCode = paint.standard?.code ?? ""
        match = paint.match
        type = paint.type
        notes = paint.notes ?? ""
        swatchHex = paint.swatchHex
        isOwned = paint.isOwned
    }

    var identityKey: String {
        isMix ? PaintIdentity.mixKey(brand: brand, name: name) : PaintIdentity.key(brand: brand, range: range, code: code)
    }

    /// Brand and code are required, or brand and name for a mix; everything
    /// else is optional.
    var missingRequiredField: Bool {
        brand.trimmedOrNil == nil || (isMix ? name.trimmedOrNil : code.trimmedOrNil) == nil
    }

    /// Every recipe line needs more than zero parts.
    var hasBadParts: Bool { recipe.contains { !($0.parts > 0) } }
}

enum PaintServiceError: LocalizedError, Equatable {
    case missingBrandOrCode
    case missingBrandOrName
    case badParts
    case badRecipePaint
    case duplicate(String)
    case inUse(paint: String, projects: [String])
    case inRecipe(paint: String, mixes: [String])

    var errorDescription: String? {
        switch self {
        case .missingBrandOrCode:
            String(localized: "A paint needs a brand and a code.")
        case .missingBrandOrName:
            String(localized: "A mix needs a brand and a name.")
        case .badParts:
            String(localized: "Each paint in a recipe needs a number of parts more than zero.")
        case .badRecipePaint:
            String(localized: "A recipe can only use paints from your catalogue that aren't mixes, each once.")
        case .duplicate(let name):
            String(localized: "“\(name)” is already in your catalogue.")
        case .inUse(let paint, let projects):
            String(localized: "“\(paint)” is used in \(projects.formatted(.list(type: .and))). Remove it from those projects first.")
        case .inRecipe(let paint, let mixes):
            String(localized: "“\(paint)” is in the recipe for \(mixes.formatted(.list(type: .and))). Take it out of those mixes first.")
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
        try applyRecipe(draft, to: paint)
        try save()
        return paint
    }

    func update(_ paint: Paint, from draft: PaintDraft) throws {
        try validate(draft, excluding: paint)
        guard draft != PaintDraft(paint: paint) else { return }
        apply(draft, to: paint)
        try applyRecipe(draft, to: paint)
        paint.updatedAt = .now
        try save()
    }

    /// Refuses while any Project or mix uses the paint. Deleting a mix
    /// deletes its recipe, never the paints in it.
    func delete(_ paint: Paint) throws {
        let projects = paint.projectNames
        guard projects.isEmpty else {
            throw PaintServiceError.inUse(paint: paint.displayName, projects: projects)
        }
        let mixes = paint.mixNames
        guard mixes.isEmpty else {
            throw PaintServiceError.inRecipe(paint: paint.displayName, mixes: mixes)
        }
        context.delete(paint)
        try save()
    }

    /// A mix's ownership comes from its recipe, so it's left alone.
    func setOwned(_ owned: Bool, for paint: Paint) throws {
        guard !paint.isMix else { return }
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

    /// Adds a colour the Project needs, before a paint is chosen for it.
    @discardableResult
    func addColour(_ standard: PaintStandard, usedFor: String = "", to project: Project) throws -> ProjectPaint {
        let row = ProjectPaint(project: project, standard: standard.code.trimmedOrNil, usedFor: usedFor.trimmedOrNil)
        row.standardSystemRaw = standard.system.rawValue
        context.insert(row)
        try save()
        return row
    }

    /// Chooses the paint for a row, replacing any earlier choice.
    func choose(_ paint: Paint, for projectPaint: ProjectPaint) throws {
        guard projectPaint.selectedPaint?.id != paint.id else { return }
        projectPaint.selectedPaint = paint
        projectPaint.updatedAt = .now
        try save()
    }

    /// Sets the guide standard's system and saves. No system clears the code.
    func setStandardSystem(_ system: PaintStandardSystem?, on projectPaint: ProjectPaint) throws {
        let raw = system?.rawValue ?? ""
        guard projectPaint.standardSystemRaw != raw else { return }
        projectPaint.standardSystemRaw = raw
        if system == nil { projectPaint.standard = nil }
        projectPaint.updatedAt = .now
        try save()
    }

    /// Updates the guide standard's code without saving; call `commit()`
    /// when editing ends.
    func setStandardCode(_ text: String, on projectPaint: ProjectPaint) {
        let value = text.isEmpty ? nil : text
        guard projectPaint.standard != value else { return }
        projectPaint.standard = value
        projectPaint.updatedAt = .now
    }

    func remove(_ projectPaint: ProjectPaint) throws {
        context.delete(projectPaint)
        try save()
    }

    /// Updates a row's notes without saving; call `commit()` when editing
    /// ends. For changes on this project only, e.g. "lightened 20%".
    func setNotes(_ text: String, on projectPaint: ProjectPaint) {
        let value = text.isEmpty ? nil : text
        guard projectPaint.notes != value else { return }
        projectPaint.notes = value
        projectPaint.updatedAt = .now
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
        guard !draft.missingRequiredField else {
            throw draft.isMix ? PaintServiceError.missingBrandOrName : PaintServiceError.missingBrandOrCode
        }
        if draft.isMix {
            guard !draft.hasBadParts else { throw PaintServiceError.badParts }
            let ids = draft.recipe.map(\.paintID)
            guard Set(ids).count == ids.count, !ids.contains(where: { $0 == paint?.id }) else {
                throw PaintServiceError.badRecipePaint
            }
        }
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
        // Values are only written when they change, so one this version
        // doesn't know (read as Custom or Not Set) is kept as it was.
        let system = draft.standardSystem
        if paint.standard?.system != system { paint.standardSystemRaw = system?.rawValue ?? "" }
        if paint.match != draft.match { paint.matchRaw = draft.match?.rawValue ?? "" }
        if paint.type != draft.type { paint.typeRaw = draft.type?.rawValue ?? "" }
        // A paint with no standard has no code or match.
        paint.standardCode = system == nil ? "" : draft.standardCode.trimmedOrNil ?? ""
        if system == nil { paint.matchRaw = "" }
        paint.notes = draft.notes.trimmedOrNil
        paint.swatchHex = draft.swatchHex.flatMap(SwatchColor.normalized)
        paint.isMix = draft.isMix
        paint.identityKey = draft.identityKey
        // A mix's ownership comes from its recipe.
        try? applyOwnership(draft.isMix ? false : draft.isOwned, to: paint)
    }

    /// Replaces a mix's recipe with the draft's, without saving. Only
    /// catalogue paints that aren't mixes can be in it.
    private func applyRecipe(_ draft: PaintDraft, to paint: Paint) throws {
        let wanted = draft.isMix ? draft.recipe : []
        let current = paint.sortedRecipe.compactMap { part in
            part.paint.map { MixPartDraft(paintID: $0.id, parts: part.parts) }
        }
        guard wanted != current else { return }
        var paints: [Paint] = []
        for line in wanted {
            let id = line.paintID
            guard let found = try context.fetch(FetchDescriptor<Paint>(predicate: #Predicate { $0.id == id })).first,
                  !found.isMix
            else { throw PaintServiceError.badRecipePaint }
            paints.append(found)
        }
        for part in paint.recipe { context.delete(part) }
        paint.recipe = []
        for (position, (line, ingredient)) in zip(wanted, paints).enumerated() {
            let part = PaintMixPart(mix: paint, paint: ingredient, parts: line.parts, position: position)
            context.insert(part)
        }
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
            context.touchEditedProjects()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension Project {
    /// The Project's paints: colours with no paint chosen first, by
    /// standard, then paints by brand and code.
    var sortedPaintRequirements: [ProjectPaint] {
        paintRequirements.sorted { first, second in
            switch (first.selectedPaint, second.selectedPaint) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil):
                return first.standardText.localizedStandardCompare(second.standardText) == .orderedAscending
            case let (a?, b?):
                let brand = a.brand.localizedStandardCompare(b.brand)
                if brand != .orderedSame { return brand == .orderedAscending }
                return a.code.localizedStandardCompare(b.code) == .orderedAscending
            }
        }
    }

    /// Rows still waiting for a paint.
    var unchosenColours: [ProjectPaint] {
        paintRequirements.filter { $0.selectedPaint == nil }
    }
}

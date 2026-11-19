import Foundation
import SwiftData

/// Every shipped schema, oldest first. Add a new `VersionedSchema` and stage
/// for each model change; never edit a schema that has shipped.
///
/// Schema 1 is the 1.0 baseline. Libraries from the 0.9 betas still open,
/// as SwiftData upgrades them itself, but their image notes are dropped.
/// Schema 2 adds build photos and schema 3 adds kits; both upgrades only
/// add, so they're lightweight. Schema 4 links kits to projects and removes
/// the project's own kit fields, after copying them into its notes.
enum BenchBookMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BenchBookSchemaV1.self, BenchBookSchemaV2.self, BenchBookSchemaV3.self, BenchBookSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: BenchBookSchemaV1.self, toVersion: BenchBookSchemaV2.self),
            .lightweight(fromVersion: BenchBookSchemaV2.self, toVersion: BenchBookSchemaV3.self),
            .custom(
                fromVersion: BenchBookSchemaV3.self,
                toVersion: BenchBookSchemaV4.self,
                willMigrate: moveKitDetailsToNotes,
                didMigrate: nil
            ),
        ]
    }

    /// Before the fields go, each project's manufacturer, kit number and
    /// scale are added to the end of its notes. Running it again never adds
    /// the line twice.
    private static func moveKitDetailsToNotes(_ context: ModelContext) throws {
        for project in try context.fetch(FetchDescriptor<BenchBookSchemaV3.Project>()) {
            let notes = KitDetailsNote.notes(
                project.notes,
                adding: KitDetailsNote.line(manufacturer: project.manufacturer,
                                            number: project.kitNumber, scale: project.scale)
            )
            if notes != project.notes { project.notes = notes }
        }
        try context.save()
    }
}

/// The line the 4.0.0 upgrade adds to a project's notes, e.g.
/// "Kit: Italeri · 1234 · 1:72".
nonisolated enum KitDetailsNote {
    /// Nil when manufacturer, number and scale are all empty.
    static func line(manufacturer: String, number: String?, scale: String) -> String? {
        let parts = [manufacturer, number ?? "", scale]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Not localized: it's stored, and the Windows app writes the same text.
        return parts.isEmpty ? nil : "Kit: " + parts.joined(separator: " · ")
    }

    /// `notes` with `line` on its own at the end, after a blank line, unless
    /// it's already the last line.
    static func notes(_ notes: String?, adding line: String?) -> String? {
        guard let line else { return notes }
        let existing = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty { return line }
        if existing.components(separatedBy: .newlines).last == line { return notes }
        return existing + "\n\n" + line
    }
}

/// The current version of each model. Update these when a new schema ships.
typealias CurrentSchema = BenchBookSchemaV4
typealias Project = CurrentSchema.Project
typealias Reference = CurrentSchema.Reference
typealias ManagedAsset = CurrentSchema.ManagedAsset
typealias Tag = CurrentSchema.Tag
typealias ReferenceTag = CurrentSchema.ReferenceTag
typealias VideoMoment = CurrentSchema.VideoMoment
typealias Paint = CurrentSchema.Paint
typealias OwnedPaint = CurrentSchema.OwnedPaint
typealias ProjectPaint = CurrentSchema.ProjectPaint
typealias AftermarketItem = CurrentSchema.AftermarketItem
typealias Markup = CurrentSchema.Markup
typealias BuildPhoto = CurrentSchema.BuildPhoto
typealias BuildPhotoTag = CurrentSchema.BuildPhotoTag
typealias Kit = CurrentSchema.Kit

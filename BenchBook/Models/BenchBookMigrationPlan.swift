import SwiftData

/// Every shipped schema, oldest first. Add a new `VersionedSchema` and stage
/// for each model change; never edit a schema that has shipped.
///
/// Schema 1 is the 1.0 baseline. Libraries from the 0.9 betas still open,
/// as SwiftData upgrades them itself, but their image notes are dropped.
enum BenchBookMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BenchBookSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

/// The current version of each model. Update these when a new schema ships.
typealias CurrentSchema = BenchBookSchemaV1
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

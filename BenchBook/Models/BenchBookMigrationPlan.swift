import SwiftData

/// Every shipped schema, oldest first. Add a new `VersionedSchema` and stage
/// for each model change; never edit a schema that has shipped.
///
/// Schema 1 is the 1.0 baseline. Libraries from the 0.9 betas still open,
/// as SwiftData upgrades them itself, but their image notes are dropped.
/// Schema 2 adds build photos and schema 3 adds kits; both upgrades only
/// add, so they're lightweight.
enum BenchBookMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BenchBookSchemaV1.self, BenchBookSchemaV2.self, BenchBookSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: BenchBookSchemaV1.self, toVersion: BenchBookSchemaV2.self),
            .lightweight(fromVersion: BenchBookSchemaV2.self, toVersion: BenchBookSchemaV3.self),
        ]
    }
}

/// The current version of each model. Update these when a new schema ships.
typealias CurrentSchema = BenchBookSchemaV3
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

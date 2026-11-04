import SwiftData

/// Every shipped schema, oldest first. Add a new `VersionedSchema` and stage
/// for each model change; never edit a schema that has shipped.
enum BenchBookMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BenchBookSchemaV1.self, BenchBookSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// V2 only adds models and an empty relationship to Project.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV1.self,
        toVersion: BenchBookSchemaV2.self
    )
}

/// The current version of each model. Update these when a new schema ships.
typealias CurrentSchema = BenchBookSchemaV2
typealias Project = CurrentSchema.Project
typealias Reference = CurrentSchema.Reference
typealias ManagedAsset = CurrentSchema.ManagedAsset
typealias Tag = CurrentSchema.Tag
typealias ReferenceTag = CurrentSchema.ReferenceTag
typealias VideoMoment = CurrentSchema.VideoMoment

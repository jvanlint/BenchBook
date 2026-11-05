import SwiftData

/// Every shipped schema, oldest first. Add a new `VersionedSchema` and stage
/// for each model change; never edit a schema that has shipped.
enum BenchBookMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BenchBookSchemaV1.self, BenchBookSchemaV2.self, BenchBookSchemaV3.self, BenchBookSchemaV4.self, BenchBookSchemaV5.self, BenchBookSchemaV6.self, BenchBookSchemaV7.self, BenchBookSchemaV8.self, BenchBookSchemaV9.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9]
    }

    /// V2 only adds models and an empty relationship to Project.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV1.self,
        toVersion: BenchBookSchemaV2.self
    )

    /// V3 only adds ImageNote and an empty relationship to Reference.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV2.self,
        toVersion: BenchBookSchemaV3.self
    )

    /// V4 only adds the paint models and an empty relationship to Project.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV3.self,
        toVersion: BenchBookSchemaV4.self
    )

    /// V5 only adds optional video details to Reference.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV4.self,
        toVersion: BenchBookSchemaV5.self
    )

    /// V6 only adds Paint.standardCode, empty for existing paints.
    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV5.self,
        toVersion: BenchBookSchemaV6.self
    )

    /// V7 only adds Tag.colorName, nil for existing tags.
    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV6.self,
        toVersion: BenchBookSchemaV7.self
    )

    /// V8 only adds optional webpage preview details to Reference.
    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV7.self,
        toVersion: BenchBookSchemaV8.self
    )

    /// V9 only adds AftermarketItem and empty relationships to Project and
    /// ManagedAsset.
    static let migrateV8toV9 = MigrationStage.lightweight(
        fromVersion: BenchBookSchemaV8.self,
        toVersion: BenchBookSchemaV9.self
    )
}

/// The current version of each model. Update these when a new schema ships.
typealias CurrentSchema = BenchBookSchemaV9
typealias Project = CurrentSchema.Project
typealias Reference = CurrentSchema.Reference
typealias ManagedAsset = CurrentSchema.ManagedAsset
typealias Tag = CurrentSchema.Tag
typealias ReferenceTag = CurrentSchema.ReferenceTag
typealias VideoMoment = CurrentSchema.VideoMoment
typealias ImageNote = CurrentSchema.ImageNote
typealias Paint = CurrentSchema.Paint
typealias OwnedPaint = CurrentSchema.OwnedPaint
typealias ProjectPaint = CurrentSchema.ProjectPaint
typealias AftermarketItem = CurrentSchema.AftermarketItem

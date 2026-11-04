import Foundation
import SwiftData

/// Schema 1: Projects only. Frozen; kept so existing libraries can migrate.
enum BenchBookSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Project.self]
    }

    /// One intended build. Descriptive fields are plain text; there is no
    /// Kit, Manufacturer, Subject or Scale taxonomy (see docs/data-model.md).
    ///
    /// Status, cover reference and the References/Paint/Aftermarket
    /// relationships are deferred until those features are built.
    @Model
    final class Project {
        /// Stable domain identity, independent of SwiftData's persistent ID.
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        /// Required and never blank. `ProjectService` enforces this.
        var name: String
        var manufacturer: String
        var subject: String
        var scale: String

        var kitNumber: String?
        var markingsScheme: String?
        var notes: String?

        init(
            id: UUID = UUID(),
            name: String,
            manufacturer: String = "",
            subject: String = "",
            scale: String = "",
            kitNumber: String? = nil,
            markingsScheme: String? = nil,
            notes: String? = nil,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.name = name
            self.manufacturer = manufacturer
            self.subject = subject
            self.scale = scale
            self.kitNumber = kitNumber
            self.markingsScheme = markingsScheme
            self.notes = notes
        }
    }
}

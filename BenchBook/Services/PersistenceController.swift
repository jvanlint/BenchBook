import Foundation
import SwiftData

enum PersistenceController {
    /// Name of the on-disk store. Inside the app sandbox it lives at
    /// ~/Library/Containers/<bundle id>/Data/Library/Application Support/BenchBook.store.
    private static let defaultStoreName = "BenchBook"

    static let schema = Schema(versionedSchema: BenchBookSchemaV1.self)

    /// Opens the local library. Failure is reported to the caller; the store
    /// is never deleted or recreated to recover from an error.
    static func makeContainer() throws -> ModelContainer {
        try makeContainer(configuration: defaultConfiguration)
    }

    static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: BenchBookMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static var defaultConfiguration: ModelConfiguration {
        #if DEBUG
        // While unit tests run inside the app, keep the app's own store in memory.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        // Debug builds can be launched with `-BenchBookStoreName <name>` to use a
        // separate store, so manual testing never touches the real library.
        if let override = UserDefaults.standard.string(forKey: "BenchBookStoreName"),
           !override.isEmpty {
            return ModelConfiguration(override, schema: schema)
        }
        #endif
        return ModelConfiguration(defaultStoreName, schema: schema)
    }
}

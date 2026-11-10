import Foundation
import SwiftData

enum PersistenceController {
    /// Name of the on-disk store. Inside the app sandbox it lives at
    /// ~/Library/Containers/<bundle id>/Data/Library/Application Support/BenchBook.store.
    private static let defaultStoreName = "BenchBook"

    static let schema = Schema(versionedSchema: CurrentSchema.self)

    /// True when running against the real library, false for tests and
    /// `-BenchBookStoreName` debug runs. Only the real library takes part
    /// in Share-extension handoff.
    static var usesDefaultLibrary: Bool {
        storeOverride == nil && !isRunningTests
    }

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

    /// The on-disk store and file library, for backup and restore. Nil while
    /// tests run, as their store is in memory.
    static var location: LibraryLocation? {
        guard !isRunningTests else { return nil }
        return LibraryLocation(storeURL: defaultConfiguration.url, libraryURL: makeAssetLibrary().rootURL)
    }

    /// Where original files live, next to the store.
    static func makeAssetLibrary() -> AssetLibrary {
        if isRunningTests {
            return AssetLibrary(rootURL: FileManager.default.temporaryDirectory
                .appending(path: "BenchBook-TestHost-\(UUID().uuidString)", directoryHint: .isDirectory))
        }
        let folderName = storeOverride.map { "\($0) Library" } ?? "Library"
        return AssetLibrary(rootURL: URL.applicationSupportDirectory
            .appending(path: folderName, directoryHint: .isDirectory))
    }

    private static var defaultConfiguration: ModelConfiguration {
        if isRunningTests {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        return ModelConfiguration(storeOverride ?? defaultStoreName, schema: schema)
    }

    /// While unit tests run inside the app, the app's own store is kept in memory.
    private static var isRunningTests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    /// Debug builds can be launched with `-BenchBookStoreName <name>` to use a
    /// separate store and file library, so manual testing never touches the real one.
    private static var storeOverride: String? {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "BenchBookStoreName"), !name.isEmpty {
            return name
        }
        #endif
        return nil
    }
}

import AppKit
import Foundation
import SwiftData

/// Restoring replaces the open library, so it happens in two parts: the
/// backup is unpacked and checked while BenchBook runs, then the libraries
/// are swapped at the next launch, before the library opens.
enum LibraryRestore {
    /// What the next launch finishes.
    struct Pending: Codable {
        /// The BenchBook that scheduled it; the swap waits for it to quit.
        var processID: Int32
        var backupDate: Date
    }

    /// The result of a restore, shown once after launch.
    enum Outcome: Equatable {
        case restored(backupDate: Date, previous: URL)
        case failed(String)
    }

    /// Unpacks a backup next to the library and checks that its files are
    /// intact and that this BenchBook can open its database. Returns what it holds.
    static func prepare(_ archive: URL, for location: LibraryLocation) async throws -> BackupManifest {
        let staging = stagingURL(for: location)
        try? FileManager.default.removeItem(at: staging)
        do {
            let manifest = try await Task.detached(priority: .userInitiated) {
                try LibraryBackup.unpack(archive, into: staging)
            }.value
            try checkOpens(staging.appending(path: LibraryBackup.storeName), manifest: manifest)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Opens the backup's database as the app would, which also upgrades
    /// one from an older BenchBook.
    private static func checkOpens(_ storeURL: URL, manifest: BackupManifest) throws {
        do {
            let container = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
            )
            _ = try ModelContext(container).fetchCount(FetchDescriptor<Project>())
        } catch {
            if manifest.appVersion.compare(Bundle.main.shortVersion, options: .numeric) == .orderedDescending {
                throw LibraryBackupError.newerFormat
            }
            throw RestoreError(message: String(localized: "BenchBook couldn't open the backup's database: \(error.localizedDescription)"))
        }
    }

    /// Restores the prepared backup at the next launch.
    static func schedule(_ manifest: BackupManifest, for location: LibraryLocation) throws {
        let pending = Pending(processID: ProcessInfo.processInfo.processIdentifier, backupDate: manifest.createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: pendingURL(for: location))
    }

    /// Forgets a prepared backup that won't be restored.
    static func discard(for location: LibraryLocation) {
        try? FileManager.default.removeItem(at: stagingURL(for: location))
    }

    /// Opens a new BenchBook, which waits for this one to quit and then
    /// finishes the restore, and quits this one.
    static func relaunch(onFailure: @escaping (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Debug runs keep their -BenchBookStoreName.
        configuration.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    onFailure(String(localized: "BenchBook couldn't reopen itself (\(error.localizedDescription)). Quit BenchBook and open it again to finish restoring."))
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// At launch, before the library opens: swaps in a scheduled backup.
    /// The current library is kept beside it, or left as it was if the swap fails.
    static func finishPending(for location: LibraryLocation) -> Outcome? {
        let fileManager = FileManager.default
        let staging = stagingURL(for: location)
        guard fileManager.fileExists(atPath: staging.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: pendingURL(for: location)),
              let pending = try? decoder.decode(Pending.self, from: data)
        else {
            // Unpacked but never confirmed, e.g. BenchBook quit while asking.
            try? fileManager.removeItem(at: staging)
            return nil
        }

        // Never swap under a BenchBook that still has the library open; try again next launch.
        guard waitForExit(of: pending.processID) else {
            return .failed(String(localized: "Another BenchBook was still open, so the backup hasn't been restored yet. Quit BenchBook and open it again to finish."))
        }
        defer { try? fileManager.removeItem(at: staging) }
        let previous = previousLibraryURL(for: location, on: .now)
        do {
            try LibraryBackup.swap(location, withUnpacked: staging, keepingCurrentIn: previous)
            return .restored(backupDate: pending.backupDate, previous: previous)
        } catch {
            // Only if the undo left it empty; otherwise it holds the library.
            if (try? fileManager.contentsOfDirectory(atPath: previous.path))?.isEmpty == true {
                try? fileManager.removeItem(at: previous)
            }
            return .failed(String(localized: "The backup couldn't be restored, so your library hasn't been changed. \(error.localizedDescription)"))
        }
    }

    /// Libraries kept from before a restore, newest first.
    static func previousLibraries(for location: LibraryLocation) -> [URL] {
        let folder = location.storeURL.deletingLastPathComponent()
        let prefix = previousLibraryPrefix(for: location)
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Locations

    /// e.g. …/Application Support/BenchBook Restore, beside the store.
    static func stagingURL(for location: LibraryLocation) -> URL {
        location.storeURL.deletingLastPathComponent()
            .appending(path: "\(storeBaseName(location)) Restore", directoryHint: .isDirectory)
    }

    private static func pendingURL(for location: LibraryLocation) -> URL {
        stagingURL(for: location).appending(path: "pending.json")
    }

    /// e.g. "BenchBook Before Restore 2026-11-10 15.30.12".
    static func previousLibraryURL(for location: LibraryLocation, on date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return location.storeURL.deletingLastPathComponent()
            .appending(path: previousLibraryPrefix(for: location) + formatter.string(from: date), directoryHint: .isDirectory)
    }

    private static func previousLibraryPrefix(for location: LibraryLocation) -> String {
        "\(storeBaseName(location)) Before Restore "
    }

    private static func storeBaseName(_ location: LibraryLocation) -> String {
        location.storeURL.deletingPathExtension().lastPathComponent
    }

    /// False if it's still running after 30 seconds.
    private static func waitForExit(of processID: Int32) -> Bool {
        guard processID != ProcessInfo.processInfo.processIdentifier else { return true }
        let deadline = Date.now.addingTimeInterval(30)
        while kill(processID, 0) == 0 {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}

struct RestoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The result of a restore, shown in the first window once.
@Observable
final class RestoreNotice {
    private(set) var outcome: LibraryRestore.Outcome?

    init(_ outcome: LibraryRestore.Outcome?) {
        self.outcome = outcome
    }

    func dismiss() {
        outcome = nil
    }
}

extension Bundle {
    /// e.g. "1.1.0".
    nonisolated var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

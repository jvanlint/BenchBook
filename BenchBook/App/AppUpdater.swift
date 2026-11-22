import Combine
import Sparkle
import SwiftUI

/// Checks for new versions with Sparkle and installs them when asked.
///
/// The feed is `SUFeedURL` in Info.plist. Every update shows Sparkle's
/// window with the release notes first: `SUAllowsAutomaticUpdates` is off, so
/// nothing downloads and installs on its own. Whether BenchBook checks on its
/// own is the user's choice: Sparkle asks on the second launch, and it's
/// in Settings › General.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Nil while unit tests run, so no update prompt can appear over them.
    private let controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

    /// False while a check or an update is already under way.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    private init() {
        guard !Self.isRunningTests else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        // Sparkle's second-launch question changes this too.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.withMutation(keyPath: \.automaticallyChecksForUpdates) {}
            }
            .store(in: &observations)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// BenchBook › Check for Updates…
struct CheckForUpdatesCommand: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

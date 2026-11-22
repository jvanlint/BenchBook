import AppKit
import Observation
import SafariServices

/// Whether BenchBook's Safari extension is turned on, for Settings.
@Observable
final class SafariExtension {
    static let identifier = "com.jasonvanlint.BenchBook.Safari"
    /// Safari accepts extensions from outside the App Store from this version.
    static let minimumSafariVersion = "18.4"

    enum State: Equatable {
        case unknown, on, off
    }

    private(set) var state: State = .unknown
    /// Safari's version, when it's older than `minimumSafariVersion`.
    private(set) var outdatedSafariVersion: String?

    func refresh() async {
        if let state = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Self.identifier) {
            self.state = state.isEnabled ? .on : .off
        } else {
            state = .unknown
        }
        outdatedSafariVersion = Self.safariVersion().flatMap { version in
            version.compare(Self.minimumSafariVersion, options: .numeric) == .orderedAscending ? version : nil
        }
    }

    func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.identifier) { _ in }
    }

    private static func safariVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

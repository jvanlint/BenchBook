import Foundation

/// The App Group shared by BenchBook and its Share extension. It holds the
/// capture inbox and a small list of Projects for the share sheet. The
/// library itself stays in the app's own container.
nonisolated enum AppGroup {
    /// Team-prefixed, matching `$(TeamIdentifierPrefix)com.jasonvanlint.BenchBook`
    /// in both targets' entitlements.
    static let identifier = "952LYY5FW2.com.jasonvanlint.BenchBook"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var inboxURL: URL? {
        containerURL?.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

/// A Project as the share sheet sees it.
nonisolated struct ProjectSummary: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var detail: String
}

/// The app publishes its Projects here; the Share extension reads them.
/// The active Project is the one most recently selected in the app or
/// shared to, and is preselected in the share sheet.
nonisolated struct ProjectDirectory {
    private static let projectsKey = "projects.v1"
    private static let activeProjectKey = "activeProjectID"

    let defaults: UserDefaults

    func publish(_ projects: [ProjectSummary]) {
        guard projects != load(), let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: Self.projectsKey)
    }

    func load() -> [ProjectSummary] {
        guard let data = defaults.data(forKey: Self.projectsKey) else { return [] }
        return (try? JSONDecoder().decode([ProjectSummary].self, from: data)) ?? []
    }

    var activeProjectID: UUID? {
        get { defaults.string(forKey: Self.activeProjectKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Self.activeProjectKey) }
    }
}

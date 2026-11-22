import Foundation

/// The App Group shared by BenchBook and its Share and Safari extensions. It
/// holds the capture inbox, results for the Safari extension, and a small
/// list of Projects and tag names. The library itself stays in the app's own
/// container.
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

    static var resultsURL: URL? {
        containerURL?.appending(path: "Results", directoryHint: .isDirectory)
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

/// The app publishes its Projects and tag names here; the extensions read them.
/// The active Project is the one most recently selected in the app or
/// shared to, and is preselected in the share sheet.
nonisolated struct ProjectDirectory {
    private static let projectsKey = "projects.v1"
    private static let activeProjectKey = "activeProjectID"
    private static let tagsKey = "tags.v1"

    let defaults: UserDefaults

    func publish(_ projects: [ProjectSummary]) {
        guard projects != load(), let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: Self.projectsKey)
    }

    func load() -> [ProjectSummary] {
        guard let data = defaults.data(forKey: Self.projectsKey) else { return [] }
        return (try? JSONDecoder().decode([ProjectSummary].self, from: data)) ?? []
    }

    /// Tag names, suggested as the user types tags in Safari.
    func publishTags(_ names: [String]) {
        guard names != loadTags() else { return }
        defaults.set(names, forKey: Self.tagsKey)
    }

    func loadTags() -> [String] {
        defaults.stringArray(forKey: Self.tagsKey) ?? []
    }

    var activeProjectID: UUID? {
        get { defaults.string(forKey: Self.activeProjectKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Self.activeProjectKey) }
    }
}

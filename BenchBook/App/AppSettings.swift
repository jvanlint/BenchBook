import Foundation

/// Preferences set in BenchBook › Settings.
nonisolated enum AppSettings {
    /// Whether webpage previews and video details are fetched automatically.
    static let fetchesLinkDetailsKey = "fetchesLinkDetails"

    /// On unless turned off in Settings.
    static func fetchesLinkDetails(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: fetchesLinkDetailsKey) as? Bool ?? true
    }

    /// Whether images open at actual size rather than fitted to the window.
    static let opensImagesAtActualSizeKey = "imageViewer.opensAtActualSize"

    static func opensImagesAtActualSize(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: opensImagesAtActualSizeKey)
    }

    /// Whether an image's note boxes are shown when it opens. The same key
    /// the viewer used to remember its last choice, so that carries over.
    static let showsNoteBoxesKey = "imageViewer.showsBoxes"

    static func showsNoteBoxes(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsNoteBoxesKey) as? Bool ?? true
    }

    /// The status new projects start with, as a `ProjectStatus` raw value.
    static let newProjectStatusKey = "newProjectStatus"

    static func newProjectStatus(in defaults: UserDefaults = .standard) -> ProjectStatus {
        defaults.string(forKey: newProjectStatusKey).flatMap(ProjectStatus.init(rawValue:)) ?? .researching
    }
}

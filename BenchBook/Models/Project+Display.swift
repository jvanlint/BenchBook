import Foundation

/// Where a build stands. Stored as `Project.statusRaw`.
nonisolated enum ProjectStatus: String, CaseIterable, Identifiable, Sendable {
    case researching
    case inProgress
    case paused
    case completed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .researching: String(localized: "Researching")
        case .inProgress: String(localized: "In Progress")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        }
    }

    var systemImage: String {
        switch self {
        case .researching: "magnifyingglass"
        case .inProgress: "hammer"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        }
    }
}

/// Which projects the sidebar lists: all of them, or one status.
nonisolated enum ProjectStatusFilter: Hashable, Sendable {
    case all
    case status(ProjectStatus)

    /// For `@AppStorage`: "all" or a status's raw value.
    init(storageValue: String) {
        self = ProjectStatus(rawValue: storageValue).map(Self.status) ?? .all
    }

    var storageValue: String {
        switch self {
        case .all: "all"
        case .status(let status): status.rawValue
        }
    }

    func includes(_ status: ProjectStatus) -> Bool {
        switch self {
        case .all: true
        case .status(let wanted): status == wanted
        }
    }
}

extension Project {
    /// What deleting this project removes, for the confirmation, e.g.
    /// "12 references, 3 image notes, 8 paints from its paint list and
    /// 2 aftermarket parts". Empty when the project holds nothing.
    var deletionSummary: String {
        let noteCount = references.reduce(0) { $0 + $1.imageNotes.count }
        let parts = [
            references.isEmpty ? nil : Self.counted(AttributedString(localized: "^[\(references.count) reference](inflect: true)")),
            noteCount == 0 ? nil : Self.counted(AttributedString(localized: "^[\(noteCount) image note](inflect: true)")),
            paintRequirements.isEmpty ? nil : Self.counted(AttributedString(
                localized: "^[\(paintRequirements.count) paint](inflect: true) from its paint list")),
            aftermarketItems.isEmpty ? nil : Self.counted(AttributedString(
                localized: "^[\(aftermarketItems.count) aftermarket part](inflect: true)")),
        ].compactMap { $0 }
        return parts.formatted(.list(type: .and))
    }

    private static func counted(_ text: AttributedString) -> String {
        String(text.inflected().characters)
    }

    /// A short line such as "Tamiya · 1:48 · F-16CJ Block 50", skipping blank fields.
    var summary: String {
        [manufacturer, scale, subject]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Projects without a stored status, such as those from before statuses
    /// existed, are Researching.
    var status: ProjectStatus {
        statusRaw.flatMap(ProjectStatus.init) ?? .researching
    }
}

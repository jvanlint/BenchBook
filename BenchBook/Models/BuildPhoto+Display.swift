import Foundation

/// Where a build photo was taken in the build. Stored as `BuildPhoto.stageRaw`.
nonisolated enum BuildPhotoStage: String, CaseIterable, Identifiable, Sendable {
    /// Work in progress, on the bench.
    case wip
    /// The finished model.
    case completed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wip: String(localized: "WIP")
        case .completed: String(localized: "Completed")
        }
    }

    var systemImage: String {
        switch self {
        case .wip: "hammer"
        case .completed: "checkmark.seal"
        }
    }
}

extension BuildPhoto {
    /// Unknown values, e.g. from a newer version, read as WIP.
    var stage: BuildPhotoStage {
        get { BuildPhotoStage(rawValue: stageRaw) ?? .wip }
        set { stageRaw = newValue.rawValue }
    }

    var tags: [Tag] {
        tagLinks.compactMap(\.tag)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The first line of the notes, if there are any.
    var caption: String? {
        notes?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap(\.trimmedOrNil)
    }

    /// The caption, or the date taken when there are no notes.
    var displayTitle: String {
        caption ?? takenAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// Box notes in the order they were added, which is also their number.
    var sortedImageNotes: [Markup] {
        markups.sorted { $0.createdAt < $1.createdAt }
    }

    /// The order photos are shown in: completed photos first, then newest
    /// taken first. Ties keep the order they were added.
    static func galleryOrder(_ lhs: BuildPhoto, _ rhs: BuildPhoto) -> Bool {
        if lhs.stage != rhs.stage { return lhs.stage == .completed }
        if lhs.takenAt != rhs.takenAt { return lhs.takenAt > rhs.takenAt }
        return lhs.createdAt > rhs.createdAt
    }
}

/// One group in the Build Photos grid: every completed photo, or the work in
/// progress from one day.
struct BuildPhotoGroup: Identifiable {
    /// "completed", or the day as "2026-11-19".
    let id: String
    let title: String
    let photos: [BuildPhoto]

    /// Completed photos first, then work in progress grouped by the day it
    /// was taken, newest day first. Within a group, newest first.
    static func groups(_ photos: [BuildPhoto], calendar: Calendar = .current) -> [BuildPhotoGroup] {
        let sorted = photos.sorted(by: BuildPhoto.galleryOrder)
        var groups: [BuildPhotoGroup] = []
        let completed = sorted.filter { $0.stage == .completed }
        if !completed.isEmpty {
            groups.append(BuildPhotoGroup(id: "completed", title: BuildPhotoStage.completed.displayName, photos: completed))
        }
        var current: (day: Date, photos: [BuildPhoto])?
        for photo in sorted where photo.stage == .wip {
            let day = calendar.startOfDay(for: photo.takenAt)
            if let open = current, open.day == day {
                current?.photos.append(photo)
            } else {
                if let open = current { groups.append(group(for: open.day, open.photos, calendar: calendar)) }
                current = (day, [photo])
            }
        }
        if let open = current { groups.append(group(for: open.day, open.photos, calendar: calendar)) }
        return groups
    }

    private static func group(for day: Date, _ photos: [BuildPhoto], calendar: Calendar) -> BuildPhotoGroup {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let id = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return BuildPhotoGroup(id: id, title: day.formatted(date: .complete, time: .omitted), photos: photos)
    }
}

extension Project {
    /// The project's build photos in gallery order.
    var sortedBuildPhotos: [BuildPhoto] {
        buildPhotos.sorted(by: BuildPhoto.galleryOrder)
    }

    /// The photo chosen for the project's header, if it still exists.
    var projectPhoto: BuildPhoto? {
        guard let projectPhotoID else { return nil }
        return buildPhotos.first { $0.id == projectPhotoID }
    }
}

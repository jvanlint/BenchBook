import Foundation
import SwiftData

/// An image the viewer and comparison window can show: a reference image
/// or a build photo. Both keep their original in a ManagedAsset and can have
/// numbered note boxes. Windows open by ID, which can be either.
enum ViewerImage: Identifiable {
    case reference(Reference)
    case buildPhoto(BuildPhoto)

    var id: UUID {
        switch self {
        case .reference(let reference): reference.id
        case .buildPhoto(let photo): photo.id
        }
    }

    var displayTitle: String {
        switch self {
        case .reference(let reference): reference.displayTitle
        case .buildPhoto(let photo): photo.displayTitle
        }
    }

    var project: Project? {
        switch self {
        case .reference(let reference): reference.project
        case .buildPhoto(let photo): photo.project
        }
    }

    var asset: ManagedAsset? {
        switch self {
        case .reference(let reference): reference.asset
        case .buildPhoto(let photo): photo.asset
        }
    }

    /// Note boxes in the order they were added, which is also their number.
    var sortedImageNotes: [Markup] {
        switch self {
        case .reference(let reference): reference.sortedImageNotes
        case .buildPhoto(let photo): photo.sortedImageNotes
        }
    }

    var tags: [Tag] {
        switch self {
        case .reference(let reference): reference.tags
        case .buildPhoto(let photo): photo.tags
        }
    }

    /// When it was added to BenchBook.
    var addedAt: Date {
        switch self {
        case .reference(let reference): reference.capturedAt
        case .buildPhoto(let photo): photo.createdAt
        }
    }

    /// The images to step through with previous and next, in the order the
    /// project shows them: its reference images newest first, or its build
    /// photos in gallery order.
    var siblingIDs: [UUID] {
        switch self {
        case .reference(let reference):
            (reference.project?.references ?? [])
                .filter { $0.kind == .image }
                .sorted { $0.capturedAt > $1.capturedAt }
                .map(\.id)
        case .buildPhoto(let photo):
            (photo.project?.sortedBuildPhotos ?? []).map(\.id)
        }
    }

    // MARK: Finding

    /// The image with this ID: a reference image or a build photo.
    @MainActor
    static func find(_ id: UUID, in context: ModelContext) -> ViewerImage? {
        find([id], in: context).first
    }

    /// The images among `ids`, in that order. IDs of references that
    /// aren't images, or of deleted items, are left out.
    @MainActor
    static func find(_ ids: [UUID], in context: ModelContext) -> [ViewerImage] {
        guard !ids.isEmpty else { return [] }
        let references = (try? context.fetch(FetchDescriptor<Reference>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let photos = (try? context.fetch(FetchDescriptor<BuildPhoto>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        var byID: [UUID: ViewerImage] = [:]
        for reference in references where reference.kind == .image { byID[reference.id] = .reference(reference) }
        for photo in photos { byID[photo.id] = .buildPhoto(photo) }
        return ids.compactMap { byID[$0] }
    }
}

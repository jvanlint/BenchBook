import Foundation

/// The rules for a side-by-side comparison window: which images it shows,
/// in what order, and how they're laid out.
nonisolated enum ImageComparison {
    /// More than this and each image is too small to compare.
    static let maximumImages = 4

    enum Arrangement: String, CaseIterable {
        /// All the images in one row.
        case row
        /// Two per row; two images are stacked.
        case grid
    }

    /// Whether a selection of this many images can be compared.
    static func canCompare(_ count: Int) -> Bool {
        (2...maximumImages).contains(count)
    }

    /// Side by side for two or three images, a 2 × 2 grid for four.
    static func defaultArrangement(for count: Int) -> Arrangement {
        count >= 4 ? .grid : .row
    }

    /// The positions of `count` images, row by row.
    static func rows(count: Int, arrangement: Arrangement) -> [[Int]] {
        guard count > 0 else { return [] }
        let perRow = switch arrangement {
        case .row: count
        case .grid: count <= 2 ? 1 : 2
        }
        return stride(from: 0, to: count, by: perRow).map { Array($0..<min($0 + perRow, count)) }
    }

    /// `added` after the images already shown, without repeats, up to the maximum.
    static func adding(_ added: [UUID], to ids: [UUID]) -> [UUID] {
        var result = ids
        for id in added where !result.contains(id) && result.count < maximumImages {
            result.append(id)
        }
        return result
    }

    /// Shows the first of `added` where `target` is, and adds the rest.
    /// An image that's already shown swaps places with `target`.
    static func replacing(_ target: UUID, with added: [UUID], in ids: [UUID]) -> [UUID] {
        guard let index = ids.firstIndex(of: target), let first = added.first else { return ids }
        var result = ids
        if let existing = result.firstIndex(of: first) {
            result.swapAt(index, existing)
        } else {
            result[index] = first
        }
        return adding(Array(added.dropFirst()), to: result)
    }

    /// The image `offset` steps from `id` in `siblings`, skipping images the
    /// window already shows, for stepping one pane through a project.
    static func neighbour(of id: UUID, offset: Int, in siblings: [UUID], skipping shown: [UUID]) -> UUID? {
        guard offset != 0, var index = siblings.firstIndex(of: id) else { return nil }
        let step = offset > 0 ? 1 : -1
        var remaining = abs(offset)
        while remaining > 0 {
            index += step
            guard siblings.indices.contains(index) else { return nil }
            if !shown.contains(siblings[index]) { remaining -= 1 }
        }
        return siblings[index]
    }
}

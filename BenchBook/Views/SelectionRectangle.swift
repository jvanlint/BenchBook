import CoreGraphics
import Foundation

/// The rules for selecting gallery tiles by dragging a rectangle across
/// them, as in Finder.
nonisolated enum SelectionRectangle {
    enum Mode: Equatable {
        /// No modifier: the rectangle's tiles become the selection.
        case replace
        /// ⇧: they're added to what was selected.
        case add
        /// ⌘: each one flips in or out of what was selected.
        case toggle

        init(command: Bool, shift: Bool) {
            self = command ? .toggle : shift ? .add : .replace
        }
    }

    /// The rectangle between where the drag started and where the pointer is.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The tiles the rectangle touches, among those shown. A rectangle with
    /// no width or height still touches the tiles it crosses.
    static func hits(_ rect: CGRect, frames: [UUID: CGRect], among shown: [UUID]) -> Set<UUID> {
        Set(shown.filter { id in
            guard let frame = frames[id] else { return false }
            return rect.minX <= frame.maxX && rect.maxX >= frame.minX && rect.minY <= frame.maxY && rect.maxY >= frame.minY
        })
    }

    /// The selection while dragging, from what was selected when the drag began.
    static func selection(base: Set<UUID>, hits: Set<UUID>, mode: Mode) -> Set<UUID> {
        switch mode {
        case .replace: hits
        case .add: base.union(hits)
        case .toggle: base.symmetricDifference(hits)
        }
    }

    /// How far to scroll each step when the pointer is near or past the top
    /// or bottom of the visible area: negative scrolls up. Faster the further
    /// out it is.
    static func autoscrollStep(pointerY: CGFloat, visibleMinY: CGFloat, visibleMaxY: CGFloat, edge: CGFloat = 16) -> CGFloat {
        let distance: CGFloat
        if pointerY < visibleMinY + edge {
            distance = -(visibleMinY + edge - pointerY)
        } else if pointerY > visibleMaxY - edge {
            distance = pointerY - (visibleMaxY - edge)
        } else {
            return 0
        }
        let speed = min(max(abs(distance) / 2, 2), 40)
        return distance < 0 ? -speed : speed
    }
}

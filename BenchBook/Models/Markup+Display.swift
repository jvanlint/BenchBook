import AppKit
import SwiftUI

/// What a markup is.
nonisolated enum MarkupKind: String, CaseIterable, Sendable {
    case note, highlight, arrow

    var displayName: String {
        switch self {
        case .note: String(localized: "Note")
        case .highlight: String(localized: "Highlight")
        case .arrow: String(localized: "Arrow")
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .highlight: "highlighter"
        case .arrow: "arrow.up.right"
        }
    }

    /// The colour new markups of this kind start with.
    var defaultColor: MarkupColor {
        switch self {
        case .note, .highlight: .yellow
        case .arrow: .red
        }
    }
}

/// The colours a markup can be, from the system palette.
nonisolated enum MarkupColor: String, CaseIterable, Identifiable, Sendable {
    case yellow, orange, red, pink, green, blue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yellow: String(localized: "Yellow")
        case .orange: String(localized: "Orange")
        case .red: String(localized: "Red")
        case .pink: String(localized: "Pink")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        }
    }

    @MainActor
    var nsColor: NSColor {
        switch self {
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        case .pink: .systemPink
        case .green: .systemGreen
        case .blue: .systemBlue
        }
    }

    /// A filled circle for menus, drawn in colour rather than as a template.
    @MainActor
    var swatch: NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Sizes and hit testing for markups, in page points.
nonisolated enum MarkupGeometry {
    static let noteWidth: CGFloat = 180
    static let notePadding: CGFloat = 8
    static let noteMinimumHeight: CGFloat = 32
    static let noteFontSize: CGFloat = 12
    static let highlightWidth: CGFloat = 14
    static let arrowWidth: CGFloat = 3
    static let arrowHeadLength: CGFloat = 14
    static let badgeDiameter: CGFloat = 18
    /// Strokes shorter than this are treated as accidental clicks.
    static let minimumStrokeLength: CGFloat = 8

    /// A note's size for its text, at its fixed width.
    @MainActor
    static func noteSize(for text: String) -> CGSize {
        let textWidth = noteWidth - notePadding * 2
        let bounds = NSAttributedString(string: text.isEmpty ? " " : text, attributes: noteTextAttributes)
            .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: noteWidth, height: max(noteMinimumHeight, ceil(bounds.height) + notePadding * 2))
    }

    @MainActor
    static var noteTextAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: noteFontSize), .foregroundColor: NSColor.black]
    }

    /// The area a stroke covers, including its width.
    static func bounds(of points: [CGPoint], lineWidth: CGFloat) -> CGRect {
        guard let first = points.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Drops points closer than `spacing` to the last kept one, keeping the end.
    static func simplified(_ points: [CGPoint], spacing: CGFloat = 1.5) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var result = [last]
        for point in points.dropFirst() where hypot(point.x - last.x, point.y - last.y) >= spacing {
            result.append(point)
            last = point
        }
        if let end = points.last, end != result.last { result.append(end) }
        return result
    }

    /// How far `point` is from the polyline through `points`.
    static func distance(from point: CGPoint, to points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        return zip(points, points.dropFirst()).map { segmentDistance(point, $0.0, $0.1) }.min() ?? .infinity
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Whether a click at `point` lands on a markup. `tolerance` is in page
    /// points, so it can grow when zoomed out.
    static func hits(_ point: CGPoint, kind: MarkupKind, rect: CGRect, points: [CGPoint], tolerance: CGFloat) -> Bool {
        switch kind {
        case .note:
            rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .highlight:
            distance(from: point, to: points) <= highlightWidth / 2 + tolerance
        case .arrow:
            distance(from: point, to: points) <= arrowWidth / 2 + tolerance
        }
    }

    /// `offset` limited so `rect` stays on the page.
    static func clampedOffset(_ offset: CGSize, moving rect: CGRect, within page: CGRect) -> CGSize {
        let dx = min(max(offset.width, page.minX - rect.minX), page.maxX - rect.maxX)
        let dy = min(max(offset.height, page.minY - rect.minY), page.maxY - rect.maxY)
        // A markup bigger than the page can't be kept inside it; let it move freely.
        return CGSize(width: rect.width > page.width ? offset.width : dx,
                      height: rect.height > page.height ? offset.height : dy)
    }

    static func clamp(_ point: CGPoint, to page: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, page.minX), page.maxX), y: min(max(point.y, page.minY), page.maxY))
    }

    /// Flattens points into stored x, y pairs, and back.
    static func flatten(_ points: [CGPoint]) -> [Double] {
        points.flatMap { [Double($0.x), Double($0.y)] }
    }

    static func points(from values: [Double]) -> [CGPoint] {
        stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
    }
}

extension Markup {
    var kind: MarkupKind { MarkupKind(rawValue: kindRaw) ?? .note }

    var color: MarkupColor { MarkupColor(rawValue: colorName) ?? kind.defaultColor }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var strokePoints: [CGPoint] { MarkupGeometry.points(from: points) }
}

extension Reference {
    /// Markups in page order, then the order they were added, which is also their number.
    var sortedMarkups: [Markup] {
        markups.sorted { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
    }
}

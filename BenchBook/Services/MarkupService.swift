import CoreGraphics
import Foundation
import SwiftData

/// Owns creating, moving, editing and deleting the markups on a PDF.
/// Positions are in page points; the PDF file is never touched.
struct MarkupService {
    let context: ModelContext

    /// Adds an empty note with its top-left corner at `point`, kept on the page.
    @discardableResult
    func addNote(to reference: Reference, page: Int, at point: CGPoint, pageBounds: CGRect,
                 color: MarkupColor = MarkupKind.note.defaultColor) throws -> Markup {
        let size = MarkupGeometry.noteSize(for: "")
        var rect = CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        let offset = MarkupGeometry.clampedOffset(.zero, moving: rect, within: pageBounds)
        rect = rect.offsetBy(dx: offset.width, dy: offset.height)
        let markup = Markup(
            reference: reference, pageIndex: page, kindRaw: MarkupKind.note.rawValue, colorName: color.rawValue,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height
        )
        context.insert(markup)
        try save()
        return markup
    }

    /// Adds a highlight along `points`. Returns nil for strokes too short to be deliberate.
    @discardableResult
    func addHighlight(to reference: Reference, page: Int, points: [CGPoint], pageBounds: CGRect,
                      color: MarkupColor = MarkupKind.highlight.defaultColor) throws -> Markup? {
        let points = MarkupGeometry.simplified(points.map { MarkupGeometry.clamp($0, to: pageBounds) })
        guard MarkupGeometry.length(of: points) >= MarkupGeometry.minimumStrokeLength else { return nil }
        return try addStroke(.highlight, to: reference, page: page, points: points,
                             lineWidth: MarkupGeometry.highlightWidth, color: color)
    }

    /// Adds an arrow pointing from `start` to `end`. Returns nil for arrows too short to be deliberate.
    @discardableResult
    func addArrow(to reference: Reference, page: Int, from start: CGPoint, to end: CGPoint, pageBounds: CGRect,
                  color: MarkupColor = MarkupKind.arrow.defaultColor) throws -> Markup? {
        let points = [start, end].map { MarkupGeometry.clamp($0, to: pageBounds) }
        guard MarkupGeometry.length(of: points) >= MarkupGeometry.minimumStrokeLength else { return nil }
        return try addStroke(.arrow, to: reference, page: page, points: points,
                             lineWidth: MarkupGeometry.arrowHeadLength, color: color)
    }

    private func addStroke(_ kind: MarkupKind, to reference: Reference, page: Int, points: [CGPoint],
                           lineWidth: CGFloat, color: MarkupColor) throws -> Markup {
        let rect = MarkupGeometry.bounds(of: points, lineWidth: lineWidth)
        let markup = Markup(
            reference: reference, pageIndex: page, kindRaw: kind.rawValue, colorName: color.rawValue,
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            points: MarkupGeometry.flatten(points)
        )
        context.insert(markup)
        try save()
        return markup
    }

    /// Moves a markup by `offset`, as far as its page allows.
    func move(_ markup: Markup, by offset: CGSize, within pageBounds: CGRect) throws {
        let offset = MarkupGeometry.clampedOffset(offset, moving: markup.rect, within: pageBounds)
        guard offset != .zero else { return }
        markup.x += offset.width
        markup.y += offset.height
        markup.points = MarkupGeometry.flatten(markup.strokePoints.map {
            CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        })
        markup.updatedAt = .now
        try save()
    }

    /// Updates the text without saving; call `commit()` when editing ends.
    /// A note grows or shrinks to fit, keeping its top edge in place.
    func setText(_ text: String, on markup: Markup) {
        guard markup.text != text else { return }
        markup.text = text
        if markup.kind == .note {
            let top = markup.y + markup.height
            let size = MarkupGeometry.noteSize(for: text)
            markup.width = size.width
            markup.height = size.height
            markup.y = top - size.height
        }
        markup.updatedAt = .now
    }

    func setColor(_ color: MarkupColor, on markup: Markup) throws {
        guard markup.color != color else { return }
        markup.colorName = color.rawValue
        markup.updatedAt = .now
        try save()
    }

    func delete(_ markup: Markup) throws {
        context.delete(markup)
        try save()
    }

    /// Saves pending edits, such as typed text.
    func commit() throws {
        guard context.hasChanges else { return }
        try save()
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

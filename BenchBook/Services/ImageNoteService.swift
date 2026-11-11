import CoreGraphics
import Foundation
import SwiftData

/// Owns creating, moving, editing and deleting image notes. They're Markup
/// notes whose box is in fractions of the image, from its top-left corner.
struct ImageNoteService {
    let context: ModelContext

    /// Adds a note for a box drawn in image pixels. Returns nil for boxes too
    /// small to be deliberate.
    @discardableResult
    func addNote(to reference: Reference, pixelRect: CGRect, imageSize: CGSize) throws -> Markup? {
        let rect = NoteGeometry.clamp(pixelRect, to: imageSize)
        guard NoteGeometry.isLargeEnough(rect) else { return nil }
        let f = NoteGeometry.fractions(of: rect, in: imageSize)
        let note = Markup.imageNote(on: reference, x: f.x, y: f.y, width: f.width, height: f.height)
        context.insert(note)
        try save()
        return note
    }

    func move(_ note: Markup, toPixelRect pixelRect: CGRect, imageSize: CGSize) throws {
        let f = NoteGeometry.fractions(of: pixelRect, in: imageSize)
        note.x = f.x
        note.y = f.y
        note.width = f.width
        note.height = f.height
        note.updatedAt = .now
        try save()
    }

    /// Updates the text without saving; call `commit()` when editing ends.
    func setText(_ text: String, on note: Markup) {
        guard note.text != text else { return }
        note.text = text
        note.updatedAt = .now
    }

    func delete(_ note: Markup) throws {
        context.delete(note)
        try save()
    }

    /// Saves pending edits, such as typed note text.
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

extension Markup {
    /// A note on an image, with its box in fractions of the image.
    static func imageNote(on reference: Reference, x: Double, y: Double, width: Double, height: Double,
                          text: String = "", createdAt: Date = .now) -> Markup {
        Markup(reference: reference, pageIndex: 0, kindRaw: MarkupKind.note.rawValue,
               colorName: MarkupKind.note.defaultColor.rawValue,
               x: x, y: y, width: width, height: height, text: text, createdAt: createdAt)
    }
}

extension Reference {
    /// An image's notes in the order they were added, which is also their
    /// number. Empty for other kinds, whose markups aren't image notes.
    var sortedImageNotes: [Markup] {
        guard kind == .image else { return [] }
        return markups.sorted { $0.createdAt < $1.createdAt }
    }
}

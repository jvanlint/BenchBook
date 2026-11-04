import CoreGraphics
import Foundation
import SwiftData

/// Owns creating, moving, editing and deleting image notes.
struct ImageNoteService {
    let context: ModelContext

    /// Adds a note for a box drawn in image pixels. Returns nil for boxes too
    /// small to be deliberate.
    @discardableResult
    func addNote(to reference: Reference, pixelRect: CGRect, imageSize: CGSize) throws -> ImageNote? {
        let rect = NoteGeometry.clamp(pixelRect, to: imageSize)
        guard NoteGeometry.isLargeEnough(rect) else { return nil }
        let f = NoteGeometry.fractions(of: rect, in: imageSize)
        let note = ImageNote(reference: reference, x: f.x, y: f.y, width: f.width, height: f.height)
        context.insert(note)
        try save()
        return note
    }

    func move(_ note: ImageNote, toPixelRect pixelRect: CGRect, imageSize: CGSize) throws {
        let f = NoteGeometry.fractions(of: pixelRect, in: imageSize)
        note.x = f.x
        note.y = f.y
        note.width = f.width
        note.height = f.height
        note.updatedAt = .now
        try save()
    }

    /// Updates the text without saving; call `commit()` when editing ends.
    func setText(_ text: String, on note: ImageNote) {
        guard note.text != text else { return }
        note.text = text
        note.updatedAt = .now
    }

    func delete(_ note: ImageNote) throws {
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

extension Reference {
    /// Notes in the order they were added, which is also their number.
    var sortedImageNotes: [ImageNote] {
        imageNotes.sorted { $0.createdAt < $1.createdAt }
    }
}

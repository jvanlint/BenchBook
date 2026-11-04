import Foundation
import SwiftData

/// Schema 4: adds the paint catalogue (Paint, OwnedPaint) and the paints
/// chosen for each Project (ProjectPaint). Everything else is unchanged
/// from schema 3. Colour standards, colours and matches come later.
/// Frozen; kept so existing libraries can migrate.
///
/// Relationship rules (docs/data-model.md):
/// - Deleting a Project deletes its References.
/// - Deleting a Reference deletes its tag links and video moments, but never
///   its ManagedAsset directly; `ReferenceService` removes unused assets.
/// - Deleting a Tag deletes its links, never the References.
/// - Deleting a Reference deletes its image notes.
/// - Deleting a Project deletes its ProjectPaints, never the Paints.
/// - A Paint can't be deleted while a ProjectPaint uses it. PaintService
///   enforces this (SwiftData doesn't enforce a .deny rule); deleting a
///   Paint deletes its ownership record.
enum BenchBookSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Project.self, Reference.self, ManagedAsset.self, Tag.self, ReferenceTag.self, VideoMoment.self,
            ImageNote.self, Paint.self, OwnedPaint.self, ProjectPaint.self,
        ]
    }

    @Model
    final class Project {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var name: String
        var manufacturer: String
        var subject: String
        var scale: String

        var kitNumber: String?
        var markingsScheme: String?
        var notes: String?

        @Relationship(deleteRule: .cascade, inverse: \Reference.project)
        var references: [Reference] = []

        @Relationship(deleteRule: .cascade, inverse: \ProjectPaint.project)
        var paintRequirements: [ProjectPaint] = []

        init(
            id: UUID = UUID(),
            name: String,
            manufacturer: String = "",
            subject: String = "",
            scale: String = "",
            kitNumber: String? = nil,
            markingsScheme: String? = nil,
            notes: String? = nil,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.name = name
            self.manufacturer = manufacturer
            self.subject = subject
            self.scale = scale
            self.kitNumber = kitNumber
            self.markingsScheme = markingsScheme
            self.notes = notes
        }
    }

    /// One saved object in a Project. See `ReferenceKind` for the kinds.
    @Model
    final class Reference {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        /// Required by the domain; optional only because SwiftData to-one
        /// relationships must be.
        var project: Project?
        var kindRaw: String

        var title: String?
        var note: String?
        /// The captured text, for text snippets only.
        var text: String?

        /// The page the item came from. Required for webpage and video links.
        var sourcePageURL: URL?
        /// The direct image/PDF URL, when known.
        var originalResourceURL: URL?
        var capturedAt: Date

        /// The stored original, for images, PDFs and Markdown files.
        @Relationship(deleteRule: .nullify, inverse: \ManagedAsset.references)
        var asset: ManagedAsset?

        @Relationship(deleteRule: .cascade, inverse: \ReferenceTag.reference)
        var tagLinks: [ReferenceTag] = []

        @Relationship(deleteRule: .cascade, inverse: \VideoMoment.reference)
        var videoMoments: [VideoMoment] = []

        /// Boxes and notes drawn on an image. Empty for other kinds.
        @Relationship(deleteRule: .cascade, inverse: \ImageNote.reference)
        var imageNotes: [ImageNote] = []

        init(
            id: UUID = UUID(),
            project: Project,
            kind: ReferenceKind,
            title: String? = nil,
            note: String? = nil,
            text: String? = nil,
            sourcePageURL: URL? = nil,
            originalResourceURL: URL? = nil,
            capturedAt: Date = .now
        ) {
            self.id = id
            self.createdAt = capturedAt
            self.updatedAt = capturedAt
            self.project = project
            self.kindRaw = kind.rawValue
            self.title = title
            self.note = note
            self.text = text
            self.sourcePageURL = sourcePageURL
            self.originalResourceURL = originalResourceURL
            self.capturedAt = capturedAt
        }
    }

    /// Metadata for one app-managed original file. The bytes live on disk
    /// under the asset library's Originals folder, never in the store.
    @Model
    final class ManagedAsset {
        /// Also the file name of the original, e.g. Originals/<id>.jpg.
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        /// Relative to the asset library root. Never an absolute path.
        var originalRelativePath: String
        var originalFilename: String?
        var mimeType: String
        var byteCount: Int64
        var sha256: String
        var pixelWidth: Int?
        var pixelHeight: Int?

        var references: [Reference] = []

        init(
            id: UUID,
            originalRelativePath: String,
            originalFilename: String?,
            mimeType: String,
            byteCount: Int64,
            sha256: String,
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.originalRelativePath = originalRelativePath
            self.originalFilename = originalFilename
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.sha256 = sha256
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    /// A lightweight label shared across the library. Not a folder.
    @Model
    final class Tag {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        /// As the user first typed it, e.g. "Wheel Well".
        var name: String
        /// Lowercased, single-spaced form used for duplicate checks.
        var normalizedName: String

        @Relationship(deleteRule: .cascade, inverse: \ReferenceTag.tag)
        var referenceLinks: [ReferenceTag] = []

        init(id: UUID = UUID(), name: String, normalizedName: String, createdAt: Date = .now) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.name = name
            self.normalizedName = normalizedName
        }
    }

    /// One Reference–Tag link.
    @Model
    final class ReferenceTag {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var reference: Reference?
        var tag: Tag?

        init(id: UUID = UUID(), reference: Reference, tag: Tag, createdAt: Date = .now) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.reference = reference
            self.tag = tag
        }
    }

    /// A point of interest in a linked video, in seconds from the start.
    @Model
    final class VideoMoment {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var reference: Reference?
        var offsetSeconds: Double
        var title: String?
        var note: String?

        init(
            id: UUID = UUID(),
            reference: Reference,
            offsetSeconds: Double,
            title: String? = nil,
            note: String? = nil,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.reference = reference
            self.offsetSeconds = offsetSeconds
            self.title = title
            self.note = note
        }
    }

    /// A box drawn on an image Reference, with a note about what it marks.
    /// The original image file is never changed.
    @Model
    final class ImageNote {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var reference: Reference?

        /// The box as fractions (0...1) of the image's width and height,
        /// measured from its top-left corner, so it's independent of zoom
        /// and screen size.
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var text: String

        init(
            id: UUID = UUID(),
            reference: Reference,
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            text: String = "",
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.reference = reference
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.text = text
        }
    }

    /// A commercial paint, e.g. Tamiya XF-54 Dark Sea Grey. Not a real-world
    /// colour standard such as FS 36270; those are modelled separately later.
    @Model
    final class Paint {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var brand: String
        var range: String
        var code: String
        var name: String
        var notes: String?
        /// Approximate on-screen colour as "#RRGGBB" (sRGB), for recognition only.
        var swatchHex: String?

        /// Normalized brand, range and code, for duplicate checks. One per library.
        var identityKey: String

        /// Present when the user owns this paint.
        @Relationship(deleteRule: .cascade, inverse: \OwnedPaint.paint)
        var ownership: OwnedPaint?

        /// Projects that use this paint. While any exist, PaintService refuses
        /// to delete the paint.
        @Relationship(deleteRule: .nullify, inverse: \ProjectPaint.selectedPaint)
        var projectSelections: [ProjectPaint] = []

        init(
            id: UUID = UUID(),
            brand: String,
            range: String = "",
            code: String,
            name: String = "",
            notes: String? = nil,
            swatchHex: String? = nil,
            identityKey: String,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.brand = brand
            self.range = range
            self.code = code
            self.name = name
            self.notes = notes
            self.swatchHex = swatchHex
            self.identityKey = identityKey
        }
    }

    /// The user owns a Paint. Removing ownership deletes only this record.
    @Model
    final class OwnedPaint {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var paint: Paint?

        init(id: UUID = UUID(), paint: Paint, createdAt: Date = .now) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.paint = paint
        }
    }

    /// A paint chosen for a Project, independent of whether it's owned.
    /// A later schema adds the real-world colour it's meant to match.
    @Model
    final class ProjectPaint {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var project: Project?
        var selectedPaint: Paint?
        /// e.g. "Upper surfaces, pylons".
        var usedFor: String?
        var notes: String?

        init(id: UUID = UUID(), project: Project, paint: Paint, usedFor: String? = nil, createdAt: Date = .now) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.project = project
            self.selectedPaint = paint
            self.usedFor = usedFor
        }
    }
}

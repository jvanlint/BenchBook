import Foundation
import SwiftData

/// Schema 9: adds AftermarketItem, a Project's decals, resin, photo-etch and
/// other parts. Everything else is unchanged from schema 8.
///
/// Relationship rules (docs/data-model.md):
/// - Deleting a Project deletes its References.
/// - Deleting a Reference deletes its tag links and video moments, but never
///   its ManagedAsset directly; `ReferenceService` removes unused assets.
/// - Deleting a Tag deletes its links, never the References.
/// - Deleting a Reference deletes its image notes.
/// - Deleting a Project deletes its ProjectPaints, never the Paints.
/// - Deleting a Project deletes its AftermarketItems. Deleting an item
///   never deletes its image's ManagedAsset directly; AftermarketService
///   removes unused assets.
/// - A Paint can't be deleted while a ProjectPaint uses it. PaintService
///   enforces this (SwiftData doesn't enforce a .deny rule); deleting a
///   Paint deletes its ownership record.
enum BenchBookSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Project.self, Reference.self, ManagedAsset.self, Tag.self, ReferenceTag.self, VideoMoment.self,
            ImageNote.self, Paint.self, OwnedPaint.self, ProjectPaint.self, AftermarketItem.self,
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

        @Relationship(deleteRule: .cascade, inverse: \AftermarketItem.project)
        var aftermarketItems: [AftermarketItem] = []

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

        // Video details, for video links. Fetched after saving; nil until
        // then, or when the site doesn't say. The poster image is stored in
        // the asset library's Posters folder, named by this Reference's id.
        var videoChannel: String?
        var videoChannelURL: URL?
        var videoDurationSeconds: Double?
        var videoPublishedAt: Date?
        var videoDescription: String?
        /// When details were last fetched. Nil means not yet, so they're
        /// fetched next time BenchBook can reach the site.
        var videoInfoFetchedAt: Date?

        // Webpage preview details, for webpages. Fetched after saving; nil
        // until then, or when the page doesn't say. The preview image is
        // stored in the Posters folder, like a video's poster.
        var linkSiteName: String?
        var linkDescription: String?
        /// When the preview was last fetched. Nil means not yet.
        var linkPreviewFetchedAt: Date?

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
        /// Aftermarket items using this file as their picture.
        var aftermarketItems: [AftermarketItem] = []

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
        /// A `TagColor` raw value such as "blue", or nil for the default tint.
        var colorName: String?

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
        /// Colour standard(s) the paint matches, as the user writes them, e.g.
        /// "FS 36270" or "RLM 76" or "FS 36375 / BS 637". Empty if unknown.
        var standardCode: String = ""

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

    /// A part bought or considered for one Project, such as decals, a resin
    /// cockpit or a 3D-printed FOD cover. Decals are a type, not a separate
    /// kind of record.
    @Model
    final class AftermarketItem {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date

        var project: Project?

        /// e.g. "50th Anniversary 2015". Required.
        var productName: String
        /// e.g. "Galaxy Models". Empty if unknown.
        var manufacturer: String
        /// The maker's catalogue number, e.g. "G48-012".
        var productNumber: String?
        /// Stored as `AftermarketType.rawValue`.
        var typeRaw: String
        /// Stored as `AftermarketStatus.rawValue`.
        var statusRaw: String
        /// Scale or the kit it fits, e.g. "1:48, Tamiya F-16C".
        var scaleCompatibility: String?
        var productURL: URL?
        var notes: String?

        /// An optional picture of the part. Not a Reference.
        @Relationship(deleteRule: .nullify, inverse: \ManagedAsset.aftermarketItems)
        var imageAsset: ManagedAsset?

        init(
            id: UUID = UUID(),
            project: Project,
            productName: String,
            manufacturer: String = "",
            typeRaw: String,
            statusRaw: String,
            createdAt: Date = .now
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.project = project
            self.productName = productName
            self.manufacturer = manufacturer
            self.typeRaw = typeRaw
            self.statusRaw = statusRaw
        }
    }
}

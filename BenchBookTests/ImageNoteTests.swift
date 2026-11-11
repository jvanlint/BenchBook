import AppKit
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BenchBook

struct NoteGeometryTests {
    let image = CGSize(width: 1000, height: 500)

    @Test func convertsBetweenPixelsAndFractions() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let f = NoteGeometry.fractions(of: rect, in: image)
        #expect(f.x == 0.1 && f.y == 0.1 && f.width == 0.2 && f.height == 0.2)
        #expect(NoteGeometry.pixelRect(x: f.x, y: f.y, width: f.width, height: f.height, in: image) == rect)
        // Same fractions on a downscaled copy land in the same place.
        #expect(NoteGeometry.pixelRect(x: f.x, y: f.y, width: f.width, height: f.height, in: CGSize(width: 500, height: 250))
                == CGRect(x: 50, y: 25, width: 100, height: 50))
    }

    @Test func keepsBoxesInsideTheImage() {
        #expect(NoteGeometry.clamp(CGRect(x: 950, y: -20, width: 100, height: 60), to: image)
                == CGRect(x: 900, y: 0, width: 100, height: 60))
        #expect(NoteGeometry.rect(from: CGPoint(x: 1200, y: 600), to: CGPoint(x: 900, y: 400), in: image)
                == CGRect(x: 900, y: 400, width: 100, height: 100))
    }

    @Test func findsAndDragsHandles() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(NoteGeometry.handle(at: CGPoint(x: 303, y: 198), in: rect, tolerance: 5) == .bottomRight)
        #expect(NoteGeometry.handle(at: CGPoint(x: 200, y: 150), in: rect, tolerance: 5) == nil)
        #expect(NoteGeometry.resize(rect, moving: .topLeft, to: CGPoint(x: 50, y: 80), in: image)
                == CGRect(x: 50, y: 80, width: 250, height: 120))
        // Dragging a corner past its opposite flips the box instead of inverting it.
        #expect(NoteGeometry.resize(rect, moving: .bottomRight, to: CGPoint(x: 40, y: 60), in: image)
                == CGRect(x: 40, y: 60, width: 60, height: 40))
        #expect(!NoteGeometry.isLargeEnough(CGRect(x: 0, y: 0, width: 4, height: 50)))
    }
}

@MainActor
struct ImageNoteServiceTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let size = CGSize(width: 800, height: 600)

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library"))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func makeImageReference() async throws -> Reference {
        let project = Fixtures.makeProject("F-16", in: context)
        let png = try Fixtures.writePNG(to: folder.file("photo.png"), width: 800, height: 600)
        let outcomes = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: png, originalFilename: nil, resourceURL: nil)], into: project)
        guard case .added(let reference) = try #require(outcomes.first) else { throw CaptureError.emptyText }
        return reference
    }

    @Test func addsMovesEditsAndDeletesNotes() async throws {
        let reference = try await makeImageReference()
        let service = ImageNoteService(context: context)
        let originalBytes = try Data(contentsOf: library.url(forRelativePath: reference.asset!.originalRelativePath))

        let note = try #require(try service.addNote(to: reference, pixelRect: CGRect(x: 80, y: 60, width: 160, height: 120), imageSize: size))
        #expect(note.x == 0.1 && note.y == 0.1 && note.width == 0.2 && note.height == 0.2)
        #expect(try service.addNote(to: reference, pixelRect: CGRect(x: 0, y: 0, width: 3, height: 3), imageSize: size) == nil)

        try service.move(note, toPixelRect: CGRect(x: 700, y: 500, width: 160, height: 120), imageSize: size)
        #expect(note.x == 0.8 && note.y == 0.8)  // clamped inside the image

        service.setText("Pitot tube is grey, not white", on: note)
        #expect(context.hasChanges)
        try service.commit()
        #expect(!context.hasChanges)

        let second = try #require(try service.addNote(to: reference, pixelRect: CGRect(x: 10, y: 10, width: 50, height: 50), imageSize: size))
        #expect(reference.sortedImageNotes.map(\.id) == [note.id, second.id])

        try service.delete(note)
        #expect(reference.sortedImageNotes.map(\.id) == [second.id])

        // Notes never touch the original file.
        #expect(try Data(contentsOf: library.url(forRelativePath: reference.asset!.originalRelativePath)) == originalBytes)
    }

    @Test func deletingReferenceDeletesItsNotes() async throws {
        let reference = try await makeImageReference()
        try ImageNoteService(context: context).addNote(to: reference, pixelRect: CGRect(x: 0, y: 0, width: 100, height: 100), imageSize: size)
        #expect(try context.fetchCount(FetchDescriptor<Markup>()) == 1)

        try ReferenceService(context: context, library: library).delete(reference)

        #expect(try context.fetchCount(FetchDescriptor<Markup>()) == 0)
    }
}

struct ImageLoaderTests {
    /// iPhone portrait photos are stored sideways with an orientation flag.
    @Test func loadsRotatedPhotosUpright() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("portrait.jpg")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let loaded = try ImageLoader.load(url)
        #expect(loaded.image.width == 20 && loaded.image.height == 40)
        #expect(loaded.metadata.pixelWidth == 20 && loaded.metadata.pixelHeight == 40)
        #expect(!loaded.isDownscaled)
    }

    @Test func rejectsDamagedFiles() throws {
        let folder = try TemporaryFolder()
        let url = try Fixtures.writeText("not an image", to: folder.file("bad.jpg"))
        #expect(throws: ImageLoader.LoadError.self) { try ImageLoader.load(url) }
    }
}

struct ImageMetadataTests {
    @Test func readsSizeCameraAndDate() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 6000,
            kCGImagePropertyPixelHeight: 4000,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyProfileName: "Display P3",
            kCGImagePropertyDepth: 8,
            kCGImagePropertyDPIWidth: 300.0,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "RF100-500mm",
                kCGImagePropertyExifDateTimeOriginal: "2015:07:18 14:32:05",
            ],
        ]
        let metadata = try #require(ImageMetadata(properties: properties))
        #expect(metadata.pixelWidth == 6000 && metadata.pixelHeight == 4000)
        #expect(metadata.megapixels == 24)
        #expect(metadata.camera == "Canon EOS R5")
        #expect(metadata.lensModel == "RF100-500mm")
        #expect(metadata.colorProfile == "Display P3")
        #expect(metadata.dpi == 300)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try #require(metadata.dateTaken))
        #expect(parts.year == 2015 && parts.month == 7 && parts.day == 18 && parts.hour == 14)
    }

    @Test func swapsSizeForRotatedPhotosAndHandlesMissingData() throws {
        let rotated = try #require(ImageMetadata(properties: [
            kCGImagePropertyPixelWidth: 4032, kCGImagePropertyPixelHeight: 3024, kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"],
        ]))
        #expect(rotated.pixelWidth == 3024 && rotated.pixelHeight == 4032)
        #expect(rotated.camera == "Apple iPhone 15 Pro")

        let bare = try #require(ImageMetadata(properties: [kCGImagePropertyPixelWidth: 10, kCGImagePropertyPixelHeight: 10]))
        #expect(bare.camera == nil && bare.dateTaken == nil && bare.dpi == nil)
        #expect(ImageMetadata(properties: [:]) == nil)
    }
}

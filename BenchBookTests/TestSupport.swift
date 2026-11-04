import AppKit
import Foundation
import SwiftData
@testable import BenchBook

/// A temporary folder removed when the value is released.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "BenchBookTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }
}

enum Fixtures {
    static func makeInMemoryContainer() throws -> ModelContainer {
        try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    static func writePNG(to url: URL, width: Int = 8, height: Int = 6, red: CGFloat = 1) throws -> URL {
        try imageRep(width: width, height: height, red: red)
            .representation(using: .png, properties: [:])!
            .write(to: url)
        return url
    }

    @discardableResult
    static func writeJPEG(to url: URL) throws -> URL {
        try imageRep(width: 10, height: 10, red: 0.5)
            .representation(using: .jpeg, properties: [:])!
            .write(to: url)
        return url
    }

    @discardableResult
    static func writePDF(to url: URL) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @discardableResult
    static func writeText(_ text: String, to url: URL) throws -> URL {
        try Data(text.utf8).write(to: url)
        return url
    }

    static func makeProject(_ name: String, in context: ModelContext) -> Project {
        let project = Project(name: name)
        context.insert(project)
        try? context.save()
        return project
    }

    private static func imageRep(width: Int, height: Int, red: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<width {
            for y in 0..<height {
                rep.setColor(NSColor(deviceRed: red, green: CGFloat(x) / CGFloat(width), blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return rep
    }
}

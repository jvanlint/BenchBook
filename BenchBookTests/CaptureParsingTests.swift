import Foundation
import Testing
@testable import BenchBook

struct VideoLinkTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s", "dQw4w9WgXcQ", 90.0 as Double?),
        ("https://youtu.be/dQw4w9WgXcQ?t=75", "dQw4w9WgXcQ", 75),
        ("https://m.youtube.com/watch?v=abc_DEF-123", "abc_DEF-123", nil),
        ("https://www.youtube.com/shorts/abc123", "abc123", nil),
        ("https://www.youtube.com/watch?v=abc123#t=1h2m3s", "abc123", 3723),
        ("https://www.youtube.com/embed/abc123?start=42", "abc123", 42),
    ])
    func parsesYouTubeLinks(link: String, id: String, start: Double?) throws {
        let parsed = try #require(VideoLink.parse(URL(string: link)!))
        #expect(parsed.provider == .youtube)
        #expect(parsed.videoID == id)
        #expect(parsed.startSeconds == start)
    }

    @Test func parsesVimeo() throws {
        let parsed = try #require(VideoLink.parse(URL(string: "https://vimeo.com/123456#t=30s")!))
        #expect(parsed.provider == .vimeo)
        #expect(parsed.startSeconds == 30)
    }

    @Test(arguments: [
        "https://www.youtube.com/",
        "https://www.youtube.com/@channel",
        "https://example.com/watch?v=abc",
        "https://www.youtube.com/watch?v=bad%20id",
    ])
    func rejectsNonVideoLinks(link: String) {
        #expect(VideoLink.parse(URL(string: link)!) == nil)
    }

    @Test(arguments: [
        ("90", 90.0 as Double?), ("90s", 90), ("1m30s", 90), ("1h2m3s", 3723), ("1:30", 90),
        ("1:02:03", 3723), ("2.5s", 2.5), ("", nil), ("-5", nil), ("abc", nil), ("1m30", nil), ("1:x", nil),
    ])
    func parsesTimestamps(text: String, seconds: Double?) {
        #expect(VideoLink.parseTimestamp(text) == seconds)
    }

    @Test func buildsPlaybackLinksAndFormatsTimes() {
        let source = URL(string: "https://youtu.be/abc123?si=tracking")!
        #expect(VideoLink.playbackURL(for: source, at: 90.7).absoluteString == "https://www.youtube.com/watch?v=abc123&t=90s")
        let other = URL(string: "https://example.com/video")!
        #expect(VideoLink.playbackURL(for: other, at: 10) == other)
        #expect(VideoLink.format(seconds: 45) == "0:45")
        #expect(VideoLink.format(seconds: 3723) == "1:02:03")
    }
}

struct TagNamesTests {
    @Test func parsesCommaSeparatedTags() {
        #expect(TagNames.parse(" wheel   well, Cockpit ,, WHEEL WELL ,decals ") == ["wheel well", "Cockpit", "decals"])
        #expect(TagNames.parse("  ") == [])
        #expect(TagNames.normalize("  Wheel   Well ") == "wheel well")
    }
}

struct FileInspectorTests {
    @Test func recognisesSupportedFilesByContent() throws {
        let folder = try TemporaryFolder()

        let png = try FileInspector.inspect(Fixtures.writePNG(to: folder.file("photo.jpg"), width: 8, height: 6))
        #expect(png.kind == .image)
        #expect(png.mimeType == "image/png")
        #expect(png.fileExtension == "png")
        #expect(png.pixelWidth == 8 && png.pixelHeight == 6)
        #expect(png.sha256.count == 64)

        let jpeg = try FileInspector.inspect(Fixtures.writeJPEG(to: folder.file("image")))
        #expect(jpeg.mimeType == "image/jpeg")

        let pdf = try FileInspector.inspect(Fixtures.writePDF(to: folder.file("manual.pdf")))
        #expect(pdf.kind == .pdf)

        let markdown = try FileInspector.inspect(Fixtures.writeText("# Notes\nWheel wells", to: folder.file("notes.md")))
        #expect(markdown.kind == .markdown)
        #expect(markdown.mimeType == "text/markdown")
    }

    @Test func rejectsUnsupportedOrDamagedFiles() throws {
        let folder = try TemporaryFolder()
        let text = try Fixtures.writeText("plain text", to: folder.file("notes.txt"))
        #expect(throws: CaptureError.unsupportedFile("notes.txt")) { try FileInspector.inspect(text) }

        let fakePDF = try Fixtures.writeText("%PDF-1.7 not really", to: folder.file("fake.pdf"))
        #expect(throws: CaptureError.unreadableFile("fake.pdf")) { try FileInspector.inspect(fakePDF) }

        let empty = try Fixtures.writeText("", to: folder.file("empty.md"))
        #expect(throws: CaptureError.unreadableFile("empty.md")) { try FileInspector.inspect(empty) }

        let binaryMarkdown = folder.file("binary.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: binaryMarkdown)
        #expect(throws: CaptureError.unreadableFile("binary.md")) { try FileInspector.inspect(binaryMarkdown) }
    }
}

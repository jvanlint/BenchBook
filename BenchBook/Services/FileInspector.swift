import CryptoKit
import Foundation
import ImageIO

/// What an incoming file turned out to be, after checking its contents.
nonisolated struct InspectedFile: Sendable, Equatable {
    var kind: ReferenceKind
    var mimeType: String
    var fileExtension: String
    var byteCount: Int64
    var sha256: String
    var pixelWidth: Int?
    var pixelHeight: Int?
}

/// Validates incoming files by content, not by name, except Markdown, which
/// has no signature and is recognised by extension plus valid UTF-8 text.
nonisolated enum FileInspector {
    static let maxFileBytes: Int64 = 200 * 1024 * 1024
    static let maxMarkdownBytes: Int64 = 5 * 1024 * 1024
    static let maxImagePixels = 300_000_000
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func inspect(_ url: URL) throws -> InspectedFile {
        let filename = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CaptureError.unreadableFile(filename)
        }
        let byteCount = Int64(size)
        guard byteCount > 0 else { throw CaptureError.unreadableFile(filename) }
        guard byteCount <= maxFileBytes else { throw CaptureError.fileTooLarge(filename) }

        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 1024) ?? Data()
        try handle.close()

        var result: InspectedFile
        if let format = ImageFormat(header: header) {
            let (width, height) = try imageDimensions(url, filename: filename)
            result = InspectedFile(
                kind: .image, mimeType: format.mimeType, fileExtension: format.fileExtension,
                byteCount: byteCount, sha256: "", pixelWidth: width, pixelHeight: height
            )
        } else if header.range(of: Data("%PDF-".utf8)) != nil {
            guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
                throw CaptureError.unreadableFile(filename)
            }
            result = InspectedFile(
                kind: .pdf, mimeType: "application/pdf", fileExtension: "pdf",
                byteCount: byteCount, sha256: ""
            )
        } else if markdownExtensions.contains(url.pathExtension.lowercased()) {
            guard byteCount <= maxMarkdownBytes else { throw CaptureError.fileTooLarge(filename) }
            guard String(data: try Data(contentsOf: url), encoding: .utf8) != nil else {
                throw CaptureError.unreadableFile(filename)
            }
            result = InspectedFile(
                kind: .markdown, mimeType: "text/markdown", fileExtension: "md",
                byteCount: byteCount, sha256: ""
            )
        } else {
            throw CaptureError.unsupportedFile(filename)
        }

        result.sha256 = try sha256(of: url)
        return result
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func imageDimensions(_ url: URL, filename: String) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw CaptureError.unreadableFile(filename)
        }
        guard width * height <= maxImagePixels else { throw CaptureError.imageTooLarge(filename) }
        return (width, height)
    }
}

/// Image formats accepted as References, identified by their file signature.
nonisolated enum ImageFormat: CaseIterable {
    case jpeg, png, webp, heic

    init?(header: Data) {
        let bytes = [UInt8](header.prefix(16))
        func ascii(_ range: Range<Int>) -> String? {
            guard bytes.count >= range.upperBound else { return nil }
            return String(bytes: bytes[range], encoding: .ascii)
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" {
            self = .webp
        } else if ascii(4..<8) == "ftyp", let brand = ascii(8..<12),
                  ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand) {
            self = .heic
        } else {
            return nil
        }
    }

    var mimeType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .webp: "image/webp"
        case .heic: "image/heic"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        case .heic: "heic"
        }
    }
}

nonisolated enum CaptureError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case unreadableFile(String)
    case fileTooLarge(String)
    case imageTooLarge(String)
    case invalidLink(String)
    case emptyText
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            String(localized: "“\(name)” isn't a supported file. BenchBook accepts JPEG, PNG, WebP and HEIC images, PDFs and Markdown files.")
        case .unreadableFile(let name):
            String(localized: "“\(name)” couldn't be read. It may be damaged or empty.")
        case .fileTooLarge(let name):
            String(localized: "“\(name)” is too large. Files can be up to 200 MB, and Markdown files up to 5 MB.")
        case .imageTooLarge(let name):
            String(localized: "“\(name)” has too many pixels. Images can be up to 300 megapixels.")
        case .invalidLink(let link):
            String(localized: "“\(link)” isn't a web link BenchBook can save.")
        case .emptyText:
            String(localized: "The shared text was empty.")
        case .projectNotFound:
            String(localized: "The project these items were sent to no longer exists.")
        }
    }
}

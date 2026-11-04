import Foundation
import ImageIO

/// Facts about an original image, read from the file's own metadata.
nonisolated struct ImageMetadata: Equatable, Sendable {
    /// Upright size of the original, after applying its orientation.
    var pixelWidth: Int
    var pixelHeight: Int
    var colorModel: String?
    var colorProfile: String?
    var bitsPerComponent: Int?
    var dpi: Int?
    var hasAlpha = false
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var dateTaken: Date?

    var megapixels: Double {
        Double(pixelWidth * pixelHeight) / 1_000_000
    }

    /// e.g. "Canon EOS R5"; avoids repeating the make when the model includes it.
    var camera: String? {
        switch (cameraMake?.trimmingCharacters(in: .whitespaces), cameraModel?.trimmingCharacters(in: .whitespaces)) {
        case let (make?, model?) where model.lowercased().hasPrefix(make.lowercased()): model
        case let (make?, model?): "\(make) \(model)"
        case let (make?, nil): make
        case let (nil, model?): model
        case (nil, nil): nil
        }
    }

    /// Reads ImageIO properties for one image.
    init?(properties: [CFString: Any]) {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        // Orientations 5–8 are rotated a quarter turn, so width and height swap.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        pixelWidth = swapped ? height : width
        pixelHeight = swapped ? width : height

        colorModel = properties[kCGImagePropertyColorModel] as? String
        colorProfile = properties[kCGImagePropertyProfileName] as? String
        bitsPerComponent = properties[kCGImagePropertyDepth] as? Int
        dpi = (properties[kCGImagePropertyDPIWidth] as? Double).map { Int($0.rounded()) }
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.nilIfBlank
        cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.nilIfBlank
        lensModel = (exif[kCGImagePropertyExifLensModel] as? String)?.nilIfBlank
        dateTaken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(Self.parseExifDate)
    }

    /// EXIF dates look like "2015:07:18 14:32:05" with no time zone.
    static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// Decodes an original image for the viewer, upright according to its
/// orientation metadata. The file on disk is never changed.
nonisolated enum ImageLoader {
    /// The largest side a GPU texture reliably supports. Bigger images are
    /// shown scaled to this; notes are stored as fractions, so they still line up.
    static let maxDisplaySide = 16_384

    struct Loaded: @unchecked Sendable {
        let image: CGImage
        let metadata: ImageMetadata

        /// True when the image is shown smaller than the original.
        var isDownscaled: Bool {
            image.width < metadata.pixelWidth || image.height < metadata.pixelHeight
        }
    }

    enum LoadError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            String(localized: "This image couldn't be opened. The saved copy may be damaged.")
        }
    }

    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let metadata = ImageMetadata(properties: properties)
        else { throw LoadError.unreadable }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(metadata.pixelWidth, metadata.pixelHeight), maxDisplaySide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LoadError.unreadable
        }
        return Loaded(image: image, metadata: metadata)
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

import Foundation

/// The records of `library.json` in a format 2 file, as spec/library-format.md
/// describes them, so the Mac and Windows apps read each other's files.
///
/// Every table is optional when reading (missing means none), and fields
/// this version doesn't know are ignored. Optional fields are left out when
/// empty. Ids are uppercase UUIDs, dates ISO 8601 UTC with milliseconds,
/// amounts of money strings like "18.50".
nonisolated struct LibraryRecords: Codable, Equatable, Sendable {
    var schemaVersion: String
    var projects: [ProjectRecord] = []
    var references: [ReferenceRecord] = []
    var assets: [AssetRecord] = []
    var tags: [TagRecord] = []
    var referenceTags: [ReferenceTagRecord] = []
    var videoMoments: [VideoMomentRecord] = []
    var markups: [MarkupRecord] = []
    var paints: [PaintRecord] = []
    var ownedPaints: [OwnedPaintRecord] = []
    var paintMixParts: [PaintMixPartRecord] = []
    var projectPaints: [ProjectPaintRecord] = []
    var aftermarketItems: [AftermarketItemRecord] = []
    var buildPhotos: [BuildPhotoRecord] = []
    var buildPhotoTags: [BuildPhotoTagRecord] = []
    var kits: [KitRecord] = []

    init(schemaVersion: String) {
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func table<T: Decodable>(_ key: CodingKeys) throws -> [T] { try c.decodeIfPresent([T].self, forKey: key) ?? [] }
        schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        projects = try table(.projects)
        references = try table(.references)
        assets = try table(.assets)
        tags = try table(.tags)
        referenceTags = try table(.referenceTags)
        videoMoments = try table(.videoMoments)
        markups = try table(.markups)
        paints = try table(.paints)
        ownedPaints = try table(.ownedPaints)
        paintMixParts = try table(.paintMixParts)
        projectPaints = try table(.projectPaints)
        aftermarketItems = try table(.aftermarketItems)
        buildPhotos = try table(.buildPhotos)
        buildPhotoTags = try table(.buildPhotoTags)
        kits = try table(.kits)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateText(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // Milliseconds are written, but accept dates without them too.
            if let date = try? Date(text, strategy: Self.dateFormat) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn't an ISO 8601 date.")
        }
        return decoder
    }

    static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    /// "2026-11-13T09:41:07.250Z", rounded to the millisecond, so reading a
    /// date and writing it again gives the same text.
    static func dateText(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let whole = seconds.remainder < 0 ? seconds.quotient - 1 : seconds.quotient
        let fraction = (seconds.remainder + 1000) % 1000
        let base = Date(timeIntervalSince1970: TimeInterval(whole))
            .formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
        return String(base.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    /// "18.50" for an amount of money; nil for no amount.
    static func decimalText(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).description(withLocale: Locale(identifier: "en_US_POSIX")) }
    }

    static func decimal(_ text: String?) -> Decimal? {
        text.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }
}

/// Text that's empty is left out, as the format says.
nonisolated func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
}

nonisolated struct ProjectRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var subject: String
    var markingsScheme: String?
    var notes: String?
    var status: String?
    var projectPhotoId: UUID?
}

nonisolated struct ReferenceRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectId: UUID
    var kind: String
    var title: String?
    var note: String?
    var text: String?
    var sourcePageUrl: String?
    var originalResourceUrl: String?
    var capturedAt: Date
    var assetId: UUID?
    var videoChannel: String?
    var videoChannelUrl: String?
    var videoDurationSeconds: Double?
    var videoPublishedAt: Date?
    var videoDescription: String?
    var videoInfoFetchedAt: Date?
    var linkSiteName: String?
    var linkDescription: String?
    var linkPreviewFetchedAt: Date?
}

nonisolated struct AssetRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var originalRelativePath: String
    var originalFilename: String?
    var mimeType: String
    var byteCount: Int64
    var sha256: String
    var pixelWidth: Int?
    var pixelHeight: Int?
}

nonisolated struct TagRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var normalizedName: String
    var color: String?
}

nonisolated struct ReferenceTagRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var referenceId: UUID
    var tagId: UUID
}

nonisolated struct BuildPhotoTagRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var buildPhotoId: UUID
    var tagId: UUID
}

nonisolated struct VideoMomentRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var referenceId: UUID
    var offsetSeconds: Double
    var title: String?
    var note: String?
}

nonisolated struct MarkupRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var referenceId: UUID?
    var buildPhotoId: UUID?
    var pageIndex: Int
    var kind: String
    var color: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var points: [Double]
    var text: String
}

nonisolated struct PaintRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var brand: String
    var range: String
    var code: String
    var name: String
    var notes: String?
    var swatchHex: String?
    var standardSystem: String
    var standardCode: String
    var match: String
    var type: String
    var isMix: Bool
    var identityKey: String
}

nonisolated struct OwnedPaintRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var paintId: UUID
}

nonisolated struct PaintMixPartRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var mixId: UUID
    var paintId: UUID
    var parts: Double
    var position: Int
}

nonisolated struct ProjectPaintRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectId: UUID
    var paintId: UUID?
    var standardSystem: String
    var standard: String?
    var usedFor: String?
    var notes: String?
}

nonisolated struct AftermarketItemRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectId: UUID
    var productName: String
    var manufacturer: String
    var productNumber: String?
    var type: String
    var status: String
    var scaleCompatibility: String?
    var productUrl: String?
    var notes: String?
    var imageAssetId: UUID?
}

nonisolated struct BuildPhotoRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectId: UUID
    var assetId: UUID
    var notes: String?
    var takenAt: Date
    var stage: String
}

nonisolated struct KitRecord: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var brand: String
    var name: String
    var scale: String?
    var number: String?
    var owned: Bool
    var status: String
    var rating: Int?
    var link: String?
    var pricePaid: String?
    var forSale: Bool
    var salePrice: String?
    var notes: String?
    var pictureAssetId: UUID?
    var projectId: UUID?
}

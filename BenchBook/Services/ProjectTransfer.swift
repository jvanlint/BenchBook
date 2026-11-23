import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// A .benchbookproject file: one project as a stored ZIP, readable by
    /// BenchBook on the Mac and on Windows.
    nonisolated static let benchBookProject = UTType(exportedAs: "com.jasonvanlint.benchbook.project")
}

/// What a project file holds, saved inside it as manifest.json.
nonisolated struct ProjectFileManifest: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var projects = 1
        var references = 0
        var buildPhotos = 0
        var paints = 0
        var aftermarketItems = 0
        var kits = 0
    }

    static let kind = "project"

    var format = 2
    var kind = Self.kind
    var createdAt: Date
    var appVersion: String
    var platform: String
    var schemaVersion: String
    /// Whether kit prices and paint ownership are in the file.
    var includesPersonalDetails: Bool
    var counts: Counts
    var files: [BackupManifest.File]
}

nonisolated enum ProjectFileError: LocalizedError, Equatable {
    case notAProjectFile
    case newerFormat
    case damaged(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .notAProjectFile:
            String(localized: "This isn't a BenchBook project file, or it's damaged.")
        case .newerFormat:
            String(localized: "This project was exported by a newer version of BenchBook. Update BenchBook, then import it.")
        case .damaged(let path):
            String(localized: "This project file is damaged: “\(path)” doesn't match what was exported. Nothing was imported.")
        case .missingFile(let name):
            String(localized: "“\(name)” is missing from your library, so the project couldn't be exported.")
        }
    }
}

// MARK: Export

/// Exports one project as a .benchbookproject file: manifest.json,
/// library.json (format 2 records) and the project's files.
struct ProjectExporter {
    /// The records and the files to put beside them, gathered on the main actor.
    struct Package: Sendable {
        var manifest: ProjectFileManifest
        var records: LibraryRecords
        /// Paths in the file, e.g. "Library/Originals/<id>.jpg", and where to read them.
        var files: [(path: String, source: URL)]
    }

    let library: AssetLibrary

    /// Kit prices and paint ownership are left out unless `includePersonalDetails`.
    func package(_ project: Project, includePersonalDetails: Bool, appVersion: String, schemaVersion: String) throws -> Package {
        var records = LibraryRecords(schemaVersion: schemaVersion)
        var files: [(String, URL)] = []
        var assets: [UUID: ManagedAsset] = [:]
        var tags: [UUID: Tag] = [:]

        records.projects = [ProjectRecord(
            id: project.id, createdAt: project.createdAt, updatedAt: project.updatedAt,
            name: project.name, subject: project.subject, markingsScheme: nonEmpty(project.markingsScheme),
            notes: nonEmpty(project.notes), status: nonEmpty(project.statusRaw),
            projectPhotoId: project.buildPhotos.contains { $0.id == project.projectPhotoID } ? project.projectPhotoID : nil
        )]

        for reference in project.references.sorted(by: { Self.inOrder($0, $1) }) {
            if let asset = reference.asset { assets[asset.id] = asset }
            records.references.append(ReferenceRecord(
                id: reference.id, createdAt: reference.createdAt, updatedAt: reference.updatedAt,
                projectId: project.id, kind: reference.kindRaw, title: nonEmpty(reference.title),
                note: nonEmpty(reference.note), text: nonEmpty(reference.text),
                sourcePageUrl: reference.sourcePageURL?.absoluteString,
                originalResourceUrl: reference.originalResourceURL?.absoluteString,
                capturedAt: reference.capturedAt, assetId: reference.asset?.id,
                videoChannel: nonEmpty(reference.videoChannel), videoChannelUrl: reference.videoChannelURL?.absoluteString,
                videoDurationSeconds: reference.videoDurationSeconds, videoPublishedAt: reference.videoPublishedAt,
                videoDescription: nonEmpty(reference.videoDescription), videoInfoFetchedAt: reference.videoInfoFetchedAt,
                linkSiteName: nonEmpty(reference.linkSiteName), linkDescription: nonEmpty(reference.linkDescription),
                linkPreviewFetchedAt: reference.linkPreviewFetchedAt
            ))
            for link in reference.tagLinks.sorted(by: { Self.inOrder($0, $1) }) {
                guard let tag = link.tag else { continue }
                tags[tag.id] = tag
                records.referenceTags.append(ReferenceTagRecord(
                    id: link.id, createdAt: link.createdAt, updatedAt: link.updatedAt, referenceId: reference.id, tagId: tag.id
                ))
            }
            for moment in reference.videoMoments.sorted(by: { Self.inOrder($0, $1) }) {
                records.videoMoments.append(VideoMomentRecord(
                    id: moment.id, createdAt: moment.createdAt, updatedAt: moment.updatedAt, referenceId: reference.id,
                    offsetSeconds: moment.offsetSeconds, title: nonEmpty(moment.title), note: nonEmpty(moment.note)
                ))
            }
            records.markups += reference.markups.sorted(by: { Self.inOrder($0, $1) }).map { Self.record($0, referenceID: reference.id, buildPhotoID: nil) }
            let poster = library.posterURL(referenceID: reference.id)
            if FileManager.default.fileExists(atPath: poster.path) {
                files.append(("Library/Posters/\(reference.id.uuidString).jpg", poster))
            }
        }

        for photo in project.buildPhotos.sorted(by: { Self.inOrder($0, $1) }) {
            guard let asset = photo.asset else { continue }
            assets[asset.id] = asset
            records.buildPhotos.append(BuildPhotoRecord(
                id: photo.id, createdAt: photo.createdAt, updatedAt: photo.updatedAt, projectId: project.id,
                assetId: asset.id, notes: nonEmpty(photo.notes), takenAt: photo.takenAt, stage: photo.stageRaw
            ))
            for link in photo.tagLinks.sorted(by: { Self.inOrder($0, $1) }) {
                guard let tag = link.tag else { continue }
                tags[tag.id] = tag
                records.buildPhotoTags.append(BuildPhotoTagRecord(
                    id: link.id, createdAt: link.createdAt, updatedAt: link.updatedAt, buildPhotoId: photo.id, tagId: tag.id
                ))
            }
            records.markups += photo.markups.sorted(by: { Self.inOrder($0, $1) }).map { Self.record($0, referenceID: nil, buildPhotoID: photo.id) }
        }

        // The paints chosen, and for mixes the paints in their recipes.
        var paints: [UUID: Paint] = [:]
        for row in project.paintRequirements.sorted(by: { Self.inOrder($0, $1) }) {
            if let paint = row.selectedPaint {
                paints[paint.id] = paint
                for part in paint.recipe { if let ingredient = part.paint { paints[ingredient.id] = ingredient } }
            }
            records.projectPaints.append(ProjectPaintRecord(
                id: row.id, createdAt: row.createdAt, updatedAt: row.updatedAt, projectId: project.id,
                paintId: row.selectedPaint?.id, standardSystem: row.standardSystemRaw,
                standard: row.standardSystemRaw.isEmpty ? nil : nonEmpty(row.standard),
                usedFor: nonEmpty(row.usedFor), notes: nonEmpty(row.notes)
            ))
        }
        for paint in paints.values.sorted(by: { $0.identityKey < $1.identityKey }) {
            records.paints.append(PaintRecord(
                id: paint.id, createdAt: paint.createdAt, updatedAt: paint.updatedAt, brand: paint.brand,
                range: paint.range, code: paint.code, name: paint.name, notes: nonEmpty(paint.notes),
                swatchHex: paint.swatchHex, standardSystem: paint.standardSystemRaw, standardCode: paint.standardCode,
                match: paint.matchRaw, type: paint.typeRaw, isMix: paint.isMix, identityKey: paint.identityKey
            ))
            if includePersonalDetails, let owned = paint.ownership, !paint.isMix {
                records.ownedPaints.append(OwnedPaintRecord(
                    id: owned.id, createdAt: owned.createdAt, updatedAt: owned.updatedAt, paintId: paint.id
                ))
            }
            for part in paint.recipe.sorted(by: { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }) {
                guard let ingredient = part.paint else { continue }
                records.paintMixParts.append(PaintMixPartRecord(
                    id: part.id, createdAt: part.createdAt, updatedAt: part.updatedAt, mixId: paint.id,
                    paintId: ingredient.id, parts: part.parts, position: part.position
                ))
            }
        }

        for item in project.aftermarketItems.sorted(by: { Self.inOrder($0, $1) }) {
            if let asset = item.imageAsset { assets[asset.id] = asset }
            records.aftermarketItems.append(AftermarketItemRecord(
                id: item.id, createdAt: item.createdAt, updatedAt: item.updatedAt, projectId: project.id,
                productName: item.productName, manufacturer: item.manufacturer, productNumber: nonEmpty(item.productNumber),
                type: item.typeRaw, status: item.statusRaw, scaleCompatibility: nonEmpty(item.scaleCompatibility),
                productUrl: item.productURL?.absoluteString, notes: nonEmpty(item.notes), imageAssetId: item.imageAsset?.id
            ))
        }

        for kit in project.kits.sorted(by: { Self.inOrder($0, $1) }) {
            if let asset = kit.picture { assets[asset.id] = asset }
            records.kits.append(KitRecord(
                id: kit.id, createdAt: kit.createdAt, updatedAt: kit.updatedAt, brand: kit.brand, name: kit.name,
                scale: nonEmpty(kit.scale), number: nonEmpty(kit.number), owned: kit.isOwned, status: kit.statusRaw,
                rating: kit.rating, link: kit.link?.absoluteString,
                pricePaid: includePersonalDetails ? LibraryRecords.decimalText(kit.pricePaid) : nil,
                forSale: includePersonalDetails && kit.isForSale,
                salePrice: includePersonalDetails ? LibraryRecords.decimalText(kit.salePrice) : nil,
                notes: nonEmpty(kit.notes), pictureAssetId: kit.picture?.id, projectId: project.id
            ))
        }

        records.tags = tags.values.sorted { $0.normalizedName < $1.normalizedName }.map { tag in
            TagRecord(id: tag.id, createdAt: tag.createdAt, updatedAt: tag.updatedAt, name: tag.name,
                      normalizedName: tag.normalizedName, color: tag.colorName)
        }
        for asset in assets.values.sorted(by: { $0.originalRelativePath < $1.originalRelativePath }) {
            let source = library.url(forRelativePath: asset.originalRelativePath)
            guard asset.originalRelativePath.hasPrefix("Originals/"),
                  ZipArchive.isSafeName(asset.originalRelativePath),
                  FileManager.default.fileExists(atPath: source.path)
            else { throw ProjectFileError.missingFile(asset.originalFilename ?? asset.originalRelativePath) }
            records.assets.append(AssetRecord(
                id: asset.id, createdAt: asset.createdAt, updatedAt: asset.updatedAt,
                originalRelativePath: asset.originalRelativePath, originalFilename: nonEmpty(asset.originalFilename),
                mimeType: asset.mimeType, byteCount: asset.byteCount, sha256: asset.sha256,
                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight
            ))
            files.append(("Library/\(asset.originalRelativePath)", source))
        }

        let counts = ProjectFileManifest.Counts(
            references: records.references.count, buildPhotos: records.buildPhotos.count,
            paints: records.paints.count, aftermarketItems: records.aftermarketItems.count, kits: records.kits.count
        )
        let manifest = ProjectFileManifest(
            createdAt: .now, appVersion: appVersion, platform: "mac", schemaVersion: schemaVersion,
            includesPersonalDetails: includePersonalDetails, counts: counts, files: []
        )
        return Package(manifest: manifest, records: records, files: files)
    }

    /// Writes the file. Off the main actor: it reads every file twice.
    nonisolated static func write(_ package: Package, to destination: URL) throws {
        let json = try LibraryRecords.encoder().encode(package.records)
        var manifest = package.manifest
        manifest.files = [BackupManifest.File(path: "library.json", size: Int64(json.count), sha256: sha256(json))]
        for file in package.files {
            manifest.files.append(BackupManifest.File(
                path: file.path, size: try LibraryBackup.fileSize(file.source), sha256: try LibraryBackup.sha256(of: file.source)
            ))
        }
        let manifestJSON = try LibraryRecords.encoder().encode(manifest)
        do {
            let writer = try ZipArchive.Writer(creating: destination)
            try writer.add("manifest.json", data: manifestJSON)
            try writer.add("library.json", data: json)
            for file in package.files {
                try writer.add(file.path, contentsOf: file.source)
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// "F-16C Viper.benchbookproject", without characters Windows or the Mac won't take.
    static func suggestedFilename(for project: Project) -> String {
        let cleaned = project.name.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? String(localized: "Project") : name
    }

    /// Oldest first, then by id, so the same project always writes the same file.
    private static func inOrder<T: PersistentModel>(_ lhs: T, _ rhs: T) -> Bool where T: Identifiable, T.ID == UUID {
        // To the millisecond, as the file stores dates.
        func time(_ value: T) -> Int64 {
            Int64((((value as? any Dated)?.createdAt ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
        }
        let a = time(lhs), b = time(rhs)
        return a != b ? a < b : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func record(_ markup: Markup, referenceID: UUID?, buildPhotoID: UUID?) -> MarkupRecord {
        MarkupRecord(
            id: markup.id, createdAt: markup.createdAt, updatedAt: markup.updatedAt, referenceId: referenceID,
            buildPhotoId: buildPhotoID, pageIndex: markup.pageIndex, kind: markup.kindRaw, color: markup.colorName,
            x: markup.x, y: markup.y, width: markup.width, height: markup.height, points: markup.points, text: markup.text
        )
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Reading

/// A project file unpacked and checked, ready to import.
nonisolated struct ProjectFile: Sendable {
    /// The unpacked file. Removed with `discard()`.
    let folder: URL
    let manifest: ProjectFileManifest
    let records: LibraryRecords
    var project: ProjectRecord { records.projects[0] }

    /// Unpacks `url` into a new folder inside `staging` and checks it: every
    /// file is listed in the manifest with the right size and checksum, and
    /// every id the records use is in the file. Nothing in the library changes.
    static func open(_ url: URL, staging: URL) throws -> ProjectFile {
        guard ZipArchive.looksLikeZip(url) else { throw ProjectFileError.notAProjectFile }
        let folder = staging.appending(path: "Import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let reader: ZipArchive.Reader
            do {
                reader = try ZipArchive.Reader(url)
                try reader.extractAll(to: folder)
            } catch let error as ZipArchive.ZipError {
                if case .damaged(let name) = error { throw ProjectFileError.damaged(name) }
                throw ProjectFileError.notAProjectFile
            }
            let decoder = LibraryRecords.decoder()
            struct Header: Decodable { var format: Int; var kind: String? }
            guard let manifestData = try? Data(contentsOf: folder.appending(path: LibraryBackup.manifestName)),
                  let header = try? decoder.decode(Header.self, from: manifestData)
            else { throw ProjectFileError.notAProjectFile }
            guard header.format <= 2 else { throw ProjectFileError.newerFormat }
            guard header.format == 2, header.kind == ProjectFileManifest.kind,
                  let manifest = try? decoder.decode(ProjectFileManifest.self, from: manifestData)
            else { throw ProjectFileError.notAProjectFile }

            // Exactly the files the manifest lists, each as it was exported.
            let listed = Set(manifest.files.map(\.path))
            let present = Set(reader.entries.filter { !$0.isDirectory }.map(\.name)).subtracting([LibraryBackup.manifestName])
            guard listed == present, listed.count == manifest.files.count, listed.contains("library.json") else {
                throw ProjectFileError.notAProjectFile
            }
            for file in manifest.files {
                let local = folder.appending(path: file.path)
                guard try LibraryBackup.fileSize(local) == file.size, try LibraryBackup.sha256(of: local) == file.sha256 else {
                    throw ProjectFileError.damaged(file.path)
                }
            }
            guard let records = try? decoder.decode(LibraryRecords.self, from: Data(contentsOf: folder.appending(path: "library.json"))),
                  Self.isComplete(records, files: listed)
            else { throw ProjectFileError.notAProjectFile }
            return ProjectFile(folder: folder, manifest: manifest, records: records)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// One project, and every id a record points at is in the file.
    static func isComplete(_ records: LibraryRecords, files: Set<String>) -> Bool {
        guard records.projects.count == 1, let project = records.projects.first,
              !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let assets = Set(records.assets.map(\.id))
        let references = Set(records.references.map(\.id))
        let photos = Set(records.buildPhotos.map(\.id))
        let tags = Set(records.tags.map(\.id))
        let paints = Set(records.paints.map(\.id))
        let mixes = Set(records.paints.filter(\.isMix).map(\.id))
        func has(_ set: Set<UUID>, _ id: UUID?) -> Bool { id.map(set.contains) ?? true }

        return records.assets.allSatisfy { asset in
            let path = asset.originalRelativePath
            return path.hasPrefix("Originals/") && path.split(separator: "/").count == 2
                && ZipArchive.isSafeName(path) && files.contains("Library/\(path)")
        }
            && records.references.allSatisfy { $0.projectId == project.id && has(assets, $0.assetId) }
            && records.buildPhotos.allSatisfy { $0.projectId == project.id && assets.contains($0.assetId) }
            && records.aftermarketItems.allSatisfy { $0.projectId == project.id && has(assets, $0.imageAssetId) }
            && records.kits.allSatisfy { ($0.projectId == nil || $0.projectId == project.id) && has(assets, $0.pictureAssetId) }
            && records.projectPaints.allSatisfy { $0.projectId == project.id && has(paints, $0.paintId) }
            && records.referenceTags.allSatisfy { references.contains($0.referenceId) && tags.contains($0.tagId) }
            && records.buildPhotoTags.allSatisfy { photos.contains($0.buildPhotoId) && tags.contains($0.tagId) }
            && records.videoMoments.allSatisfy { references.contains($0.referenceId) }
            && records.markups.allSatisfy { markup in
                switch (markup.referenceId, markup.buildPhotoId) {
                case (let id?, nil): references.contains(id)
                case (nil, let id?): photos.contains(id)
                default: false
                }
            }
            && records.ownedPaints.allSatisfy { paints.contains($0.paintId) && !mixes.contains($0.paintId) }
            && records.paintMixParts.allSatisfy {
                mixes.contains($0.mixId) && paints.contains($0.paintId) && !mixes.contains($0.paintId) && $0.parts > 0
            }
            && records.paints.allSatisfy { !$0.brand.isEmpty && ($0.isMix ? !$0.name.isEmpty : !$0.code.isEmpty) }
            && records.tags.allSatisfy { !TagNames.normalize($0.name).isEmpty }
    }
}

// MARK: Import

/// Adds a project file's project to the library, merging with what's there:
/// paints are matched by identity key and tags by name, and neither is
/// changed. Files already in the library (same asset id and checksum) are
/// shared, not copied again.
struct ProjectImporter {
    enum Mode: Equatable {
        /// The project isn't in the library.
        case add
        /// Replace the library's project that has the same id.
        case replace
        /// Keep the library's project and add this one beside it, with new ids
        /// and "Copy" after its name.
        case keepBoth
    }

    struct Summary: Equatable {
        var projectID: UUID
        var projectName: String
        var paintsAdded = 0
        var paintsMatched = 0
        var tagsAdded = 0
        var kitsAdded = 0
        /// Kits already in the library that now belong to the imported project.
        var kitsMatched = 0
        /// Kits already in the library in another project, left there.
        var kitsInOtherProjects: [String] = []
    }

    let context: ModelContext
    let library: AssetLibrary

    /// The library's project with the file's project id, if any.
    func existingProject(for file: ProjectFile) throws -> Project? {
        let id = file.project.id
        return try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
    }

    func importProject(_ file: ProjectFile, mode: Mode) throws -> Summary {
        let records = file.records
        let source = records.projects[0]
        let replaced = mode == .replace ? try existingProject(for: file) : nil
        var copied: [URL] = []

        // Records of the replaced project free their ids; nothing else's do.
        var taken = Set<UUID>()
        let replacedIDs = replaced.map { Self.ownedIDs($0) } ?? []
        for id in try allIDs() where !replacedIDs.contains(id) { taken.insert(id) }
        func newID(_ id: UUID) -> UUID {
            let id = mode == .keepBoth || taken.contains(id) ? UUID() : id
            taken.insert(id)
            return id
        }

        do {
            let oldAssets = replaced.map { project in
                project.references.compactMap(\.asset) + project.aftermarketItems.compactMap(\.imageAsset)
                    + project.buildPhotos.compactMap(\.asset) + project.kits.compactMap(\.picture)
            } ?? []
            let oldReferenceIDs = replaced?.references.map(\.id) ?? []
            var kitsToRelink: [UUID: Kit] = [:]
            if let replaced {
                for kit in replaced.kits { kitsToRelink[kit.id] = kit }
                context.delete(replaced)
            }

            // Files: shared when the library already has the same one.
            var assets: [UUID: ManagedAsset] = [:]
            for record in records.assets {
                let assetID = record.id
                if let existing = try context.fetch(FetchDescriptor<ManagedAsset>(predicate: #Predicate { $0.id == assetID })).first,
                   existing.sha256 == record.sha256 {
                    assets[record.id] = existing
                    continue
                }
                let id = taken.contains(record.id) ? UUID() : record.id
                taken.insert(id)
                let ext = (record.originalRelativePath as NSString).pathExtension
                let path = AssetLibrary.originalRelativePath(assetID: id, fileExtension: ext)
                try library.copyOriginal(from: file.folder.appending(path: "Library/\(record.originalRelativePath)"), toRelativePath: path)
                copied.append(library.url(forRelativePath: path))
                let asset = ManagedAsset(
                    id: id, originalRelativePath: path, originalFilename: record.originalFilename, mimeType: record.mimeType,
                    byteCount: record.byteCount, sha256: record.sha256, pixelWidth: record.pixelWidth,
                    pixelHeight: record.pixelHeight, createdAt: record.createdAt
                )
                asset.updatedAt = record.updatedAt
                context.insert(asset)
                assets[record.id] = asset
            }

            var summary = Summary(projectID: UUID(), projectName: source.name)
            let tags = try mergeTags(records.tags, summary: &summary, taken: &taken)
            let paints = try mergePaints(records, summary: &summary, taken: &taken)

            let name = mode == .keepBoth ? String(localized: "\(source.name) Copy") : source.name
            let project = Project(id: newID(source.id), name: name, subject: source.subject,
                                  markingsScheme: source.markingsScheme, notes: source.notes, createdAt: source.createdAt)
            project.statusRaw = source.status
            project.updatedAt = source.updatedAt
            context.insert(project)
            summary.projectID = project.id
            summary.projectName = name

            var references: [UUID: Reference] = [:]
            for record in records.references {
                let reference = Reference(
                    id: newID(record.id), project: project, kind: ReferenceKind(rawValue: record.kind) ?? .note,
                    title: record.title, note: record.note, text: record.text,
                    sourcePageURL: record.sourcePageUrl.flatMap(URL.init(string:)),
                    originalResourceURL: record.originalResourceUrl.flatMap(URL.init(string:)),
                    capturedAt: record.capturedAt
                )
                reference.kindRaw = record.kind
                reference.createdAt = record.createdAt
                reference.updatedAt = record.updatedAt
                reference.asset = record.assetId.flatMap { assets[$0] }
                reference.videoChannel = record.videoChannel
                reference.videoChannelURL = record.videoChannelUrl.flatMap(URL.init(string:))
                reference.videoDurationSeconds = record.videoDurationSeconds
                reference.videoPublishedAt = record.videoPublishedAt
                reference.videoDescription = record.videoDescription
                reference.videoInfoFetchedAt = record.videoInfoFetchedAt
                reference.linkSiteName = record.linkSiteName
                reference.linkDescription = record.linkDescription
                reference.linkPreviewFetchedAt = record.linkPreviewFetchedAt
                context.insert(reference)
                references[record.id] = reference
            }
            for record in records.referenceTags {
                guard let reference = references[record.referenceId], let tag = tags[record.tagId],
                      !reference.tagLinks.contains(where: { $0.tag === tag })
                else { continue }
                context.insert(ReferenceTag(id: newID(record.id), reference: reference, tag: tag, createdAt: record.createdAt))
            }
            for record in records.videoMoments {
                guard let reference = references[record.referenceId] else { continue }
                let moment = VideoMoment(id: newID(record.id), reference: reference, offsetSeconds: record.offsetSeconds,
                                         title: record.title, note: record.note, createdAt: record.createdAt)
                moment.updatedAt = record.updatedAt
                context.insert(moment)
            }

            var photos: [UUID: BuildPhoto] = [:]
            for record in records.buildPhotos {
                let photo = BuildPhoto(id: newID(record.id), project: project, notes: record.notes, takenAt: record.takenAt,
                                       stageRaw: record.stage, createdAt: record.createdAt)
                photo.updatedAt = record.updatedAt
                photo.asset = assets[record.assetId]
                context.insert(photo)
                photos[record.id] = photo
            }
            project.projectPhotoID = source.projectPhotoId.flatMap { photos[$0]?.id }
            for record in records.buildPhotoTags {
                guard let photo = photos[record.buildPhotoId], let tag = tags[record.tagId],
                      !photo.tagLinks.contains(where: { $0.tag === tag })
                else { continue }
                context.insert(BuildPhotoTag(id: newID(record.id), photo: photo, tag: tag, createdAt: record.createdAt))
            }
            for record in records.markups {
                let markup = Markup(
                    id: newID(record.id), reference: record.referenceId.flatMap { references[$0] },
                    buildPhoto: record.buildPhotoId.flatMap { photos[$0] }, pageIndex: record.pageIndex,
                    kindRaw: record.kind, colorName: record.color, x: record.x, y: record.y, width: record.width,
                    height: record.height, points: record.points, text: record.text, createdAt: record.createdAt
                )
                markup.updatedAt = record.updatedAt
                context.insert(markup)
            }

            for record in records.projectPaints {
                let row = ProjectPaint(id: newID(record.id), project: project, paint: record.paintId.flatMap { paints[$0] },
                                       standard: record.standard, usedFor: record.usedFor, createdAt: record.createdAt)
                row.standardSystemRaw = record.standardSystem
                row.notes = record.notes
                row.updatedAt = record.updatedAt
                context.insert(row)
            }

            for record in records.aftermarketItems {
                let item = AftermarketItem(id: newID(record.id), project: project, productName: record.productName,
                                           manufacturer: record.manufacturer, typeRaw: record.type,
                                           statusRaw: record.status, createdAt: record.createdAt)
                item.productNumber = record.productNumber
                item.scaleCompatibility = record.scaleCompatibility
                item.productURL = record.productUrl.flatMap(URL.init(string:))
                item.notes = record.notes
                item.imageAsset = record.imageAssetId.flatMap { assets[$0] }
                item.updatedAt = record.updatedAt
                context.insert(item)
            }

            for record in records.kits {
                let kitID = record.id
                if let existing = try kitsToRelink[kitID]
                    ?? context.fetch(FetchDescriptor<Kit>(predicate: #Predicate { $0.id == kitID })).first {
                    // A kit is one physical box: it isn't copied, and a kit
                    // building another project stays there.
                    if let other = existing.project, other !== replaced {
                        summary.kitsInOtherProjects.append(existing.displayName)
                    } else {
                        existing.project = project
                        summary.kitsMatched += 1
                    }
                    continue
                }
                let kit = Kit(id: newID(record.id), brand: record.brand, name: record.name, scale: record.scale,
                              number: record.number, isOwned: record.owned, statusRaw: record.status,
                              createdAt: record.createdAt)
                kit.rating = record.rating.flatMap { (1...5).contains($0) ? $0 : nil }
                kit.link = record.link.flatMap(URL.init(string:))
                kit.pricePaid = LibraryRecords.decimal(record.pricePaid)
                kit.isForSale = record.forSale
                kit.salePrice = LibraryRecords.decimal(record.salePrice)
                kit.notes = record.notes
                kit.picture = record.pictureAssetId.flatMap { assets[$0] }
                kit.project = project
                kit.updatedAt = record.updatedAt
                context.insert(kit)
                summary.kitsAdded += 1
            }

            // One save for the whole project. The project keeps the dates it
            // was exported with, so no "last updated" touch.
            try context.save()

            for id in oldReferenceIDs {
                try? FileManager.default.removeItem(at: library.posterURL(referenceID: id))
            }
            for (oldID, reference) in references {
                let poster = file.folder.appending(path: "Library/Posters/\(oldID.uuidString).jpg")
                guard FileManager.default.fileExists(atPath: poster.path) else { continue }
                try? FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
                let destination = library.posterURL(referenceID: reference.id)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: poster, to: destination)
            }
            let cleanup = ReferenceService(context: context, library: library)
            for asset in Dictionary(oldAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values {
                try? cleanup.removeAssetIfUnused(asset)
            }
            return summary
        } catch {
            context.rollback()
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Tags by name, ignoring case and spacing; new ones keep their colour.
    private func mergeTags(_ records: [TagRecord], summary: inout Summary, taken: inout Set<UUID>) throws -> [UUID: Tag] {
        var tags: [UUID: Tag] = [:]
        for record in records {
            let normalized = TagNames.normalize(record.name)
            if let existing = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.normalizedName == normalized })).first {
                tags[record.id] = existing
                continue
            }
            let id = taken.contains(record.id) ? UUID() : record.id
            taken.insert(id)
            let tag = Tag(id: id, name: record.name, normalizedName: normalized, createdAt: record.createdAt)
            tag.colorName = record.color
            tag.updatedAt = record.updatedAt
            context.insert(tag)
            tags[record.id] = tag
            summary.tagsAdded += 1
        }
        return tags
    }

    /// Paints by identity key. A paint already in the catalogue is used as it
    /// is; a new one is added, owned only if the file says so.
    private func mergePaints(_ records: LibraryRecords, summary: inout Summary, taken: inout Set<UUID>) throws -> [UUID: Paint] {
        let owned = Dictionary(records.ownedPaints.map { ($0.paintId, $0) }, uniquingKeysWith: { first, _ in first })
        var paints: [UUID: Paint] = [:]
        var added: [UUID: Paint] = [:]
        for record in records.paints {
            let key = record.isMix
                ? PaintIdentity.mixKey(brand: record.brand, name: record.name)
                : PaintIdentity.key(brand: record.brand, range: record.range, code: record.code)
            if let existing = try PaintService(context: context).existingPaint(identityKey: key)
                ?? paints.values.first(where: { $0.identityKey == key }) {
                paints[record.id] = existing
                summary.paintsMatched += 1
                continue
            }
            let id = taken.contains(record.id) ? UUID() : record.id
            taken.insert(id)
            let paint = Paint(id: id, brand: record.brand, range: record.range, code: record.code, name: record.name,
                              notes: record.notes, swatchHex: record.swatchHex.flatMap(SwatchColor.normalized),
                              identityKey: key, createdAt: record.createdAt)
            paint.standardSystemRaw = record.standardSystem
            paint.standardCode = record.standardSystem.isEmpty ? "" : record.standardCode
            paint.matchRaw = record.standardSystem.isEmpty ? "" : record.match
            paint.typeRaw = record.type
            paint.isMix = record.isMix
            paint.updatedAt = record.updatedAt
            context.insert(paint)
            if let ownership = owned[record.id], !record.isMix {
                let ownershipID = taken.contains(ownership.id) ? UUID() : ownership.id
                taken.insert(ownershipID)
                let owned = OwnedPaint(id: ownershipID, paint: paint, createdAt: ownership.createdAt)
                owned.updatedAt = ownership.updatedAt
                context.insert(owned)
            }
            paints[record.id] = paint
            added[record.id] = paint
            summary.paintsAdded += 1
        }
        // Recipes only for mixes this import added.
        for record in records.paintMixParts.sorted(by: { $0.position < $1.position }) {
            guard let mix = added[record.mixId], let ingredient = paints[record.paintId], !ingredient.isMix,
                  !mix.recipe.contains(where: { $0.paint === ingredient })
            else { continue }
            let id = taken.contains(record.id) ? UUID() : record.id
            taken.insert(id)
            context.insert(PaintMixPart(id: id, mix: mix, paint: ingredient, parts: record.parts,
                                        position: record.position, createdAt: record.createdAt))
        }
        return paints
    }

    /// Every id in use, so imported records never reuse one.
    private func allIDs() throws -> [UUID] {
        func ids<T: PersistentModel & Identifiable>(_ type: T.Type) throws -> [UUID] where T.ID == UUID {
            try context.fetch(FetchDescriptor<T>()).map(\.id)
        }
        return try ids(Project.self) + ids(Reference.self) + ids(ManagedAsset.self) + ids(Tag.self)
            + ids(ReferenceTag.self) + ids(VideoMoment.self) + ids(Markup.self) + ids(Paint.self)
            + ids(OwnedPaint.self) + ids(PaintMixPart.self) + ids(ProjectPaint.self) + ids(AftermarketItem.self)
            + ids(BuildPhoto.self) + ids(BuildPhotoTag.self) + ids(Kit.self)
    }

    /// The ids of a project's own records, freed when it's replaced.
    private static func ownedIDs(_ project: Project) -> Set<UUID> {
        var ids: Set<UUID> = [project.id]
        for reference in project.references {
            ids.insert(reference.id)
            ids.formUnion(reference.tagLinks.map(\.id))
            ids.formUnion(reference.videoMoments.map(\.id))
            ids.formUnion(reference.markups.map(\.id))
        }
        for photo in project.buildPhotos {
            ids.insert(photo.id)
            ids.formUnion(photo.tagLinks.map(\.id))
            ids.formUnion(photo.markups.map(\.id))
        }
        ids.formUnion(project.paintRequirements.map(\.id))
        ids.formUnion(project.aftermarketItems.map(\.id))
        return ids
    }
}

/// Records with a creation date, for a stable export order.
protocol Dated { var createdAt: Date { get } }
extension Reference: Dated {}
extension BuildPhoto: Dated {}
extension ProjectPaint: Dated {}
extension AftermarketItem: Dated {}
extension Kit: Dated {}
extension ReferenceTag: Dated {}
extension BuildPhotoTag: Dated {}
extension VideoMoment: Dated {}
extension Markup: Dated {}

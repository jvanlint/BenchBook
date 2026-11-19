import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// The result of adding one file to a project's build photos.
enum BuildPhotoOutcome {
    case added(BuildPhoto)
    /// The same file is already one of this project's build photos.
    case duplicate(existing: BuildPhoto, filename: String)
    case failed(filename: String, error: Error)
}

nonisolated enum BuildPhotoError: LocalizedError, Equatable {
    case notAPhoto(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAPhoto(let name):
            String(localized: "“\(name)” isn't a photo. Build photos can be JPEG, PNG, WebP or HEIC images.")
        case .exportFailed(let name):
            String(localized: "“\(name)” couldn't be exported.")
        }
    }
}

/// Owns build photos: adding them, editing their notes, date, stage and tags,
/// choosing the project photo, deleting them, and exporting copies.
struct BuildPhotoService {
    let context: ModelContext
    let library: AssetLibrary

    // MARK: Adding

    /// Adds image files to the project's build photos. Each original is
    /// checked, copied byte for byte into the library and saved before it
    /// counts as added.
    ///
    /// A file identical to one added earlier in the same call is left out
    /// without a report: some apps, such as Photos, offer one dragged photo
    /// twice, as data and as a file.
    func addPhotos(_ files: [(url: URL, filename: String?)], to project: Project) async -> [BuildPhotoOutcome] {
        var outcomes: [BuildPhotoOutcome] = []
        var addedNow = Set<UUID>()
        for file in files {
            let name = file.filename ?? file.url.lastPathComponent
            do {
                let outcome = try await addPhoto(at: file.url, filename: name, to: project)
                switch outcome {
                case .added(let photo):
                    addedNow.insert(photo.id)
                case .duplicate(let existing, _) where addedNow.contains(existing.id):
                    continue
                default:
                    break
                }
                outcomes.append(outcome)
            } catch {
                outcomes.append(.failed(filename: name, error: error))
            }
        }
        return outcomes
    }

    private func addPhoto(at url: URL, filename: String, to project: Project) async throws -> BuildPhotoOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let (inspected, taken) = try await Task.detached(priority: .userInitiated) {
            (try FileInspector.inspect(url), Self.dateTaken(of: url))
        }.value
        guard inspected.kind == .image else { throw BuildPhotoError.notAPhoto(filename) }

        if let existing = project.buildPhotos.first(where: { $0.asset?.sha256 == inspected.sha256 }) {
            return .duplicate(existing: existing, filename: filename)
        }

        let assetID = UUID()
        let relativePath = AssetLibrary.originalRelativePath(assetID: assetID, fileExtension: inspected.fileExtension)
        let library = library
        try await Task.detached(priority: .userInitiated) {
            try library.copyOriginal(from: url, toRelativePath: relativePath)
        }.value

        let asset = ManagedAsset(
            id: assetID,
            originalRelativePath: relativePath,
            originalFilename: filename.trimmedOrNil,
            mimeType: inspected.mimeType,
            byteCount: inspected.byteCount,
            sha256: inspected.sha256,
            pixelWidth: inspected.pixelWidth,
            pixelHeight: inspected.pixelHeight
        )
        let photo = BuildPhoto(project: project, takenAt: taken ?? .now, stageRaw: BuildPhotoStage.wip.rawValue)
        context.insert(asset)
        context.insert(photo)
        photo.asset = asset
        do {
            try save()
        } catch {
            library.removeFiles(assetID: assetID, originalRelativePath: relativePath)
            throw error
        }
        return .added(photo)
    }

    /// When the photo was taken, from its EXIF date, if it has one.
    nonisolated static func dateTaken(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else { return nil }
        return ImageMetadata.parseExifDate(text)
    }

    // MARK: Editing

    /// Saves the details sheet: notes, date taken, stage and tags.
    func update(_ photo: BuildPhoto, notes: String, takenAt: Date, stage: BuildPhotoStage, tagsText: String) throws {
        photo.notes = notes.trimmedOrNil
        photo.takenAt = takenAt
        photo.stage = stage
        do {
            try setTags(TagNames.parse(tagsText), on: photo)
        } catch {
            context.rollback()
            throw error
        }
        photo.updatedAt = .now
        try save()
    }

    func setStage(_ stage: BuildPhotoStage, on photos: [BuildPhoto]) throws {
        for photo in photos where photo.stage != stage {
            photo.stage = stage
            photo.updatedAt = .now
        }
        try save()
    }

    /// Shows the photo in its project's header, or none when nil.
    func setProjectPhoto(_ photo: BuildPhoto?, for project: Project) throws {
        project.projectPhotoID = photo?.id
        project.updatedAt = .now
        try save()
    }

    /// Replaces the photo's tags, reusing library Tags by normalized name.
    /// Does not save.
    func setTags(_ names: [String], on photo: BuildPhoto) throws {
        let wanted = Dictionary(names.map { (TagNames.normalize($0), $0) }, uniquingKeysWith: { first, _ in first })

        for link in photo.tagLinks where !wanted.keys.contains(link.tag?.normalizedName ?? "") {
            context.delete(link)
        }
        let existing = Set(photo.tagLinks.compactMap { $0.tag?.normalizedName })
        let missing = wanted.filter { !existing.contains($0.key) }
        guard !missing.isEmpty else { return }

        let normalizedNames = Array(missing.keys)
        let found = try context.fetch(FetchDescriptor<Tag>(
            predicate: #Predicate { normalizedNames.contains($0.normalizedName) }
        ))
        var tagsByName = Dictionary(found.map { ($0.normalizedName, $0) }, uniquingKeysWith: { first, _ in first })

        for (normalized, name) in missing.sorted(by: { $0.key < $1.key }) {
            let tag = tagsByName[normalized] ?? {
                let tag = Tag(name: name, normalizedName: normalized)
                context.insert(tag)
                tagsByName[normalized] = tag
                return tag
            }()
            context.insert(BuildPhotoTag(photo: photo, tag: tag))
        }
    }

    // MARK: Deleting

    /// Deletes the photos, then their stored files if nothing else uses them.
    /// A deleted project photo stops showing in the header.
    func delete(_ photos: [BuildPhoto]) throws {
        let assets = photos.compactMap(\.asset)
        for photo in photos {
            if let project = photo.project, project.projectPhotoID == photo.id {
                project.projectPhotoID = nil
            }
            context.delete(photo)
        }
        try save()
        let references = ReferenceService(context: context, library: library)
        for asset in Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values {
            try references.removeAssetIfUnused(asset)
        }
    }

    // MARK: Exporting

    /// Saves copies of the photos' originals into `folder`, named by date and
    /// caption. With `removingLocation`, GPS data is left out of each copy;
    /// the pixels are copied as they are, without re-compressing. The
    /// originals in the library are never changed. Returns the files written.
    @discardableResult
    func export(_ photos: [BuildPhoto], to folder: URL, removingLocation: Bool) throws -> [URL] {
        var written: [URL] = []
        var used = Set<String>()
        for photo in photos.sorted(by: { $0.takenAt < $1.takenAt }) {
            guard let asset = photo.asset else { continue }
            let source = library.url(forRelativePath: asset.originalRelativePath)
            let ext = (asset.originalRelativePath as NSString).pathExtension
            let name = Self.uniqueName(Self.exportBaseName(for: photo), ext: ext, avoiding: &used, in: folder)
            let destination = folder.appending(path: name, directoryHint: .notDirectory)
            if removingLocation {
                try Self.copyWithoutLocation(from: source, to: destination, name: photo.displayTitle)
            } else {
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    throw BuildPhotoError.exportFailed(photo.displayTitle)
                }
            }
            written.append(destination)
        }
        return written
    }

    /// e.g. "2026-11-19 Cockpit painted", using the Mac's time zone for the date.
    static func exportBaseName(for photo: BuildPhoto, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: photo.takenAt)
        guard let caption = photo.caption else { return date }
        // Characters Finder or other systems can't use in names become spaces.
        let cleaned = caption
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.isEmpty ? date : "\(date) \(String(cleaned.prefix(80)))"
    }

    private static func uniqueName(_ base: String, ext: String, avoiding used: inout Set<String>, in folder: URL) -> String {
        var name = "\(base).\(ext)"
        var number = 2
        while used.contains(name.lowercased())
                || FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            name = "\(base) \(number).\(ext)"
            number += 1
        }
        used.insert(name.lowercased())
        return name
    }

    /// Copies the image data and metadata, leaving out GPS, without
    /// decoding or re-compressing the pixels.
    nonisolated static func copyWithoutLocation(from source: URL, to destination: URL, name: String) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil)
        else { throw BuildPhotoError.exportFailed(name) }
        let options: [CFString: Any] = [
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(output, imageSource, options as CFDictionary, &error) else {
            // Formats that can't be copied losslessly are written again
            // without their GPS dictionary.
            try rewriteWithoutLocation(imageSource, type: type, to: destination, name: name)
            return
        }
    }

    private nonisolated static func rewriteWithoutLocation(_ source: CGImageSource, type: CFString, to destination: URL, name: String) throws {
        try? FileManager.default.removeItem(at: destination)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw BuildPhotoError.exportFailed(name) }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImagePropertyGPSDictionary] = nil
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw BuildPhotoError.exportFailed(name) }
    }

    private func save() throws {
        do {
            context.touchEditedProjects()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

import Foundation
import SwiftData

enum AftermarketError: LocalizedError, Equatable {
    case blankName
    case invalidURL
    case notAnImage(String)
    case noPageImage

    var errorDescription: String? {
        switch self {
        case .blankName: String(localized: "A part needs a name.")
        case .invalidURL: String(localized: "The product page isn't a web address.")
        case .notAnImage(let name): String(localized: "“\(name)” isn't an image BenchBook can use.")
        case .noPageImage: String(localized: "The product page doesn't offer a picture BenchBook can use.")
        }
    }
}

/// Owns a Project's aftermarket items: saving, status changes, deleting and
/// their pictures, including cleanup of stored files.
struct AftermarketService {
    let context: ModelContext
    let library: AssetLibrary

    @discardableResult
    func create(in project: Project, from draft: AftermarketDraft) throws -> AftermarketItem {
        try validate(draft)
        let item = AftermarketItem(
            project: project,
            productName: "",
            typeRaw: draft.type.rawValue,
            statusRaw: draft.status.rawValue
        )
        context.insert(item)
        apply(draft, to: item)
        project.updatedAt = .now
        try save()
        return item
    }

    func update(_ item: AftermarketItem, from draft: AftermarketDraft) throws {
        try validate(draft)
        guard draft != AftermarketDraft(item: item) else { return }
        apply(draft, to: item)
        item.updatedAt = .now
        try save()
    }

    func setStatus(_ status: AftermarketStatus, for items: [AftermarketItem]) throws {
        for item in items where item.statusRaw != status.rawValue {
            item.statusRaw = status.rawValue
            item.updatedAt = .now
        }
        try save()
    }

    /// Deletes the items, then their pictures if nothing else uses them.
    func delete(_ items: [AftermarketItem]) throws {
        let assets = items.compactMap(\.imageAsset)
        for item in items { context.delete(item) }
        try save()
        for asset in assets { try references.removeAssetIfUnused(asset) }
    }

    // MARK: Pictures

    /// Copies an image file into the library as the item's picture,
    /// replacing any earlier one.
    func setImage(from url: URL, on item: AftermarketItem) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let inspected = try await Task.detached(priority: .userInitiated) {
            try FileInspector.inspect(url)
        }.value
        guard inspected.kind == .image else { throw AftermarketError.notAnImage(url.lastPathComponent) }

        let assetID = UUID()
        let relativePath = AssetLibrary.originalRelativePath(assetID: assetID, fileExtension: inspected.fileExtension)
        let library = library
        try await Task.detached(priority: .userInitiated) {
            try library.copyOriginal(from: url, toRelativePath: relativePath)
        }.value

        let asset = ManagedAsset(
            id: assetID,
            originalRelativePath: relativePath,
            originalFilename: url.lastPathComponent,
            mimeType: inspected.mimeType,
            byteCount: inspected.byteCount,
            sha256: inspected.sha256,
            pixelWidth: inspected.pixelWidth,
            pixelHeight: inspected.pixelHeight
        )
        let previous = item.imageAsset
        context.insert(asset)
        item.imageAsset = asset
        item.updatedAt = .now
        do {
            try save()
        } catch {
            library.removeFiles(assetID: assetID, originalRelativePath: relativePath)
            throw error
        }
        if let previous { try references.removeAssetIfUnused(previous) }
    }

    func removeImage(from item: AftermarketItem) throws {
        guard let previous = item.imageAsset else { return }
        item.imageAsset = nil
        item.updatedAt = .now
        try save()
        try references.removeAssetIfUnused(previous)
    }

    /// Downloads the picture a product page offers for link previews into
    /// `folder`, ready for `setImage(from:on:)`.
    static func downloadPageImage(from page: URL, into folder: URL, fetcher: PageInfoFetcher = PageInfoFetcher()) async throws -> URL {
        let info: PageInfo
        do {
            info = try await fetcher.info(for: page)
        } catch {
            throw AftermarketError.noPageImage
        }
        // Site icons aren't pictures of the product.
        guard let preview = await fetcher.previewImage(for: PageInfo(imageURLs: info.imageURLs)) else {
            throw AftermarketError.noPageImage
        }
        let isPNG = preview.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let file = folder.appending(path: "Product Image.\(isPNG ? "png" : "jpg")", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try preview.data.write(to: file, options: .atomic)
        return file
    }

    // MARK: Helpers

    private var references: ReferenceService { ReferenceService(context: context, library: library) }

    private func validate(_ draft: AftermarketDraft) throws {
        guard draft.hasValidName else { throw AftermarketError.blankName }
        guard draft.hasValidURL else { throw AftermarketError.invalidURL }
    }

    private func apply(_ draft: AftermarketDraft, to item: AftermarketItem) {
        item.productName = draft.productName.trimmedOrNil ?? ""
        item.manufacturer = draft.manufacturer.trimmedOrNil ?? ""
        item.productNumber = draft.productNumber.trimmedOrNil
        item.typeRaw = draft.type.rawValue
        item.statusRaw = draft.status.rawValue
        item.scaleCompatibility = draft.scaleCompatibility.trimmedOrNil
        item.productURL = draft.parsedURL
        item.notes = draft.notes.trimmedOrNil
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

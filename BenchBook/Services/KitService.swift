import Foundation
import SwiftData

enum KitError: LocalizedError, Equatable {
    case blankBrand
    case blankName
    case invalidLink
    case invalidPrice

    var errorDescription: String? {
        switch self {
        case .blankBrand: String(localized: "A kit needs a brand.")
        case .blankName: String(localized: "A kit needs a name.")
        case .invalidLink: String(localized: "The link isn't a web address.")
        case .invalidPrice: String(localized: "Enter prices as numbers, such as 18.50.")
        }
    }
}

/// Owns the Kits catalogue: adding and editing kits, copies, status and sale
/// changes, pictures and deleting, including cleanup of stored files.
///
/// Kits belong to the library, so changing one doesn't change any project's
/// last updated date.
struct KitService {
    let context: ModelContext
    let library: AssetLibrary

    // MARK: Adding and editing

    @discardableResult
    func create(from draft: KitDraft) throws -> Kit {
        try validate(draft)
        let kit = Kit(brand: "", name: "")
        context.insert(kit)
        apply(draft, to: kit)
        try save()
        return kit
    }

    func update(_ kit: Kit, from draft: KitDraft) throws {
        try validate(draft)
        guard draft != KitDraft(kit: kit) else { return }
        apply(draft, to: kit)
        kit.updatedAt = .now
        try save()
    }

    /// Another box of the same kit: the same brand, name, scale, number, link
    /// and picture, owned and BNIB, with no price, rating, sale details or notes.
    @discardableResult
    func addCopy(of kit: Kit) throws -> Kit {
        let copy = Kit(brand: kit.brand, name: kit.name, scale: kit.scale, number: kit.number)
        context.insert(copy)
        copy.link = kit.link
        copy.picture = kit.picture
        try save()
        return copy
    }

    /// The other entries for the same kit, oldest first. `excluding` leaves
    /// out the kit being edited.
    func copies(brand: String, number: String?, scale: String?, link: URL?, excluding kit: Kit? = nil) throws -> [Kit] {
        try context.fetch(FetchDescriptor<Kit>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { other in
                other.persistentModelID != kit?.persistentModelID
                    && KitIdentity.isSameKit(brand: brand, number: number, scale: scale, link: link,
                                             as: (other.brand, other.number, other.scale, other.link))
            }
    }

    func setStatus(_ status: KitStatus, for kits: [Kit]) throws {
        for kit in kits where kit.statusRaw != status.rawValue {
            kit.status = status
            kit.updatedAt = .now
        }
        try save()
    }

    func setOwned(_ owned: Bool, for kits: [Kit]) throws {
        for kit in kits where kit.isOwned != owned {
            kit.isOwned = owned
            kit.updatedAt = .now
        }
        try save()
    }

    /// Turning For Sale off keeps the sale price.
    func setForSale(_ forSale: Bool, for kits: [Kit]) throws {
        for kit in kits where kit.isForSale != forSale {
            kit.isForSale = forSale
            kit.updatedAt = .now
        }
        try save()
    }

    /// Deletes the kits, then their pictures if nothing else uses them.
    func delete(_ kits: [Kit]) throws {
        let assets = Dictionary(kits.compactMap(\.picture).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for kit in kits { context.delete(kit) }
        try save()
        for asset in assets.values { try references.removeAssetIfUnused(asset) }
    }

    // MARK: Pictures

    /// Copies an image file into the library as the kit's box art, replacing
    /// any earlier one. Other copies of the kit keep their picture.
    func setPicture(from url: URL, on kit: Kit) async throws {
        let asset = try await PictureImporter(library: library).importImage(from: url)
        let previous = kit.picture
        context.insert(asset)
        kit.picture = asset
        kit.updatedAt = .now
        do {
            try save()
        } catch {
            library.removeFiles(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            throw error
        }
        if let previous { try references.removeAssetIfUnused(previous) }
    }

    func removePicture(from kit: Kit) throws {
        guard let previous = kit.picture else { return }
        kit.picture = nil
        kit.updatedAt = .now
        try save()
        try references.removeAssetIfUnused(previous)
    }

    // MARK: Helpers

    private var references: ReferenceService { ReferenceService(context: context, library: library) }

    private func validate(_ draft: KitDraft) throws {
        guard draft.hasValidBrand else { throw KitError.blankBrand }
        guard draft.hasValidName else { throw KitError.blankName }
        guard draft.hasValidLink else { throw KitError.invalidLink }
        guard draft.hasValidPricePaid, draft.hasValidSalePrice else { throw KitError.invalidPrice }
    }

    private func apply(_ draft: KitDraft, to kit: Kit) {
        kit.brand = draft.brand.trimmedOrNil ?? ""
        kit.name = draft.name.trimmedOrNil ?? ""
        kit.scale = draft.scale.trimmedOrNil
        kit.number = draft.number.trimmedOrNil
        kit.isOwned = draft.isOwned
        // Leaves an unknown stored status alone unless the user chose another.
        if draft.status != kit.status { kit.status = draft.status }
        kit.stars = draft.stars
        kit.link = draft.parsedLink
        kit.pricePaid = KitPrice.parse(draft.pricePaid)
        kit.isForSale = draft.isForSale
        kit.salePrice = KitPrice.parse(draft.salePrice)
        kit.notes = draft.notes.trimmedOrNil
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

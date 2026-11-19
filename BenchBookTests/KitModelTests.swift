import Foundation
import SwiftData
import Testing
@testable import BenchBook

@MainActor
struct KitModelTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func makeAsset() -> ManagedAsset {
        let asset = ManagedAsset(
            id: UUID(), originalRelativePath: "Originals/box.jpg", originalFilename: "box.jpg",
            mimeType: "image/jpeg", byteCount: 10, sha256: "abc"
        )
        context.insert(asset)
        return asset
    }

    @Test func aNewKitIsOwnedBNIBAndNotForSale() {
        let kit = Kit(brand: "Italeri", name: "Super Cobra")
        #expect(kit.isOwned)
        #expect(kit.status == .bnib)
        #expect(kit.stars == nil)
        #expect(!kit.isForSale)
        #expect(kit.createdAt == kit.updatedAt)
    }

    @Test func savesEveryField() throws {
        let kit = Kit(brand: "Italeri", name: "Super Cobra", scale: "1:72", number: "07109", isOwned: false)
        kit.status = .wip
        kit.stars = 4
        kit.link = URL(string: "https://www.scalemates.com/kits/italeri-1-72-super-cobra--123")
        kit.pricePaid = Decimal(string: "18.50")
        kit.isForSale = true
        kit.salePrice = Decimal(string: "25")
        kit.notes = "Missing a decal sheet"
        kit.picture = makeAsset()
        context.insert(kit)
        try context.save()

        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<Kit>()).first)
        #expect(fetched.brand == "Italeri")
        #expect(fetched.number == "07109")
        #expect(!fetched.isOwned)
        #expect(fetched.statusRaw == "wip")
        #expect(fetched.rating == 4)
        #expect(fetched.pricePaid == Decimal(string: "18.50"))
        #expect(fetched.salePrice == 25)
        #expect(fetched.picture?.originalFilename == "box.jpg")
    }

    @Test func unknownStatusReadsAsBNIBAndIsKept() {
        let kit = Kit(brand: "Revell", name: "Spitfire", statusRaw: "painted")
        #expect(kit.status == .bnib)
        #expect(kit.statusRaw == "painted")
        kit.status = .built
        #expect(kit.statusRaw == "built")
    }

    @Test func ratingIsOneToFiveStarsOrNone() {
        let kit = Kit(brand: "Revell", name: "Spitfire")
        kit.stars = 5
        #expect(kit.rating == 5)
        kit.stars = 9
        #expect(kit.rating == nil)
        kit.rating = 0
        #expect(kit.stars == nil)
    }

    @Test func aKitPictureIsInUseAndSurvivesCleanUp() throws {
        let asset = makeAsset()
        let kit = Kit(brand: "Italeri", name: "Super Cobra")
        kit.picture = asset
        context.insert(kit)
        try context.save()

        #expect(!asset.isUnused)
        let service = ReferenceService(context: context, library: library)
        try service.removeAssetIfUnused(asset)
        #expect(try context.fetch(FetchDescriptor<ManagedAsset>()).count == 1)

        // Deleting the kit leaves the file to the cleaner, which then removes it.
        context.delete(kit)
        try context.save()
        #expect(asset.isUnused)
        #expect(try service.reconcileLibrary() >= 1)
        #expect(try context.fetch(FetchDescriptor<ManagedAsset>()).isEmpty)
    }

    @Test func copiesCanShareOnePicture() throws {
        let asset = makeAsset()
        for _ in 0..<2 {
            let kit = Kit(brand: "Italeri", name: "Super Cobra")
            kit.picture = asset
            context.insert(kit)
        }
        try context.save()
        #expect(asset.kits.count == 2)
    }
}

@MainActor
struct KitMigrationTests {
    @Test func schemaTwoLibraryOpensWithKits() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")
        let photoID = UUID()

        do {
            let schema = Schema(versionedSchema: BenchBookSchemaV2.self)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
            let context = old.mainContext
            let project = BenchBookSchemaV2.Project(name: "Spitfire", manufacturer: "Airfix", scale: "1:48")
            context.insert(project)
            context.insert(BenchBookSchemaV2.Reference(project: project, kind: .note, text: "Cockpit green"))
            let asset = BenchBookSchemaV2.ManagedAsset(
                id: UUID(), originalRelativePath: "Originals/photo.jpg", originalFilename: "photo.jpg",
                mimeType: "image/jpeg", byteCount: 10, sha256: "abc"
            )
            context.insert(asset)
            let photo = BenchBookSchemaV2.BuildPhoto(id: photoID, project: project, notes: "Cockpit done",
                                                     takenAt: .now, stageRaw: "wip")
            context.insert(photo)
            photo.asset = asset
            project.projectPhotoID = photoID
            try context.save()
        }

        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let context = container.mainContext
        let project = try #require(try context.fetch(FetchDescriptor<Project>()).first)
        #expect(project.name == "Spitfire")
        #expect(project.notes == "Kit: Airfix · 1:48")
        #expect(project.kits.isEmpty)
        #expect(project.references.first?.text == "Cockpit green")
        #expect(project.buildPhotos.first?.notes == "Cockpit done")
        #expect(project.projectPhoto?.asset?.originalFilename == "photo.jpg")
        #expect(project.buildPhotos.first?.asset?.kits.isEmpty == true)
        #expect(try context.fetch(FetchDescriptor<Kit>()).isEmpty)

        context.insert(Kit(brand: "Airfix", name: "Spitfire Mk.I", scale: "1:48"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Kit>()).count == 1)
    }
}

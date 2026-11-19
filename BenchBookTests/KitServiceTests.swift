import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct KitPriceTests {
    @Test(arguments: [
        ("25", "25"), ("25.00", "25"), ("25,00", "25"), ("18.5", "18.5"), ("$18.50", "18.5"),
        ("€ 18,50", "18.5"), ("1,250", "1250"), ("1,250.00", "1250"), ("1.250,00", "1250"),
        ("1 250,50", "1250.5"), ("1,250,000", "1250000"), ("0.250", "0.25"), (" 0", "0"),
    ])
    func readsPrices(text: String, expected: String) {
        #expect(KitPrice.parse(text) == Decimal(string: expected))
    }

    @Test(arguments: ["", "  ", "free", "-5", "£"])
    func rejectsTextThatIsntAPrice(text: String) {
        #expect(KitPrice.parse(text) == nil)
    }

    @Test func writesPlainNumbersWhateverTheRegion() {
        #expect(KitPrice.plain(Decimal(string: "18.5")!) == "18.50")
        #expect(KitPrice.plain(1250) == "1250.00")
        #expect(KitPrice.display(Decimal(string: "18.5")!, locale: Locale(identifier: "de_DE")).contains("18,50"))
    }
}

struct KitIdentityTests {
    private func same(_ a: (String, String?, String?, String?), _ b: (String, String?, String?, String?)) -> Bool {
        KitIdentity.isSameKit(brand: a.0, number: a.1, scale: a.2, link: a.3.flatMap(URL.init(string:)),
                              as: (b.0, b.1, b.2, b.3.flatMap(URL.init(string:))))
    }

    @Test func matchesBrandNumberAndScaleIgnoringCaseAndSpaces() {
        #expect(same(("Italeri", "1234", "1:72", nil), ("italeri ", "12 34", "1 : 72", nil)))
        #expect(!same(("Italeri", "1234", "1:72", nil), ("Italeri", "1234", "1:48", nil)))
        #expect(!same(("Italeri", "1234", "1:72", nil), ("Revell", "1234", "1:72", nil)))
    }

    @Test func withoutANumberOnlyTheScalematesAddressCounts() {
        #expect(!same(("Italeri", nil, "1:72", nil), ("Italeri", nil, "1:72", nil)))
        #expect(same(("Italeri", nil, nil, "https://www.scalemates.com/kits/italeri-1234--100/"),
                     ("Other", "9", "1:48", "https://scalemates.com/kits/Italeri-1234--100?ref=x")))
        #expect(!same(("Italeri", nil, nil, "https://shop.example.com/kit/1"),
                      ("Italeri", nil, nil, "https://shop.example.com/kit/1")))
    }
}

@MainActor
struct KitServiceTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: KitService { KitService(context: context, library: library) }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    private func draft(_ brand: String = "Italeri", _ name: String = "Super Cobra") -> KitDraft {
        var draft = KitDraft()
        draft.brand = brand
        draft.name = name
        draft.scale = "1:72"
        draft.number = "1234"
        return draft
    }

    @Test func createsAKitFromTheEditor() throws {
        var draft = draft()
        draft.brand = "  Italeri "
        draft.link = "scalemates.com/kits/italeri-1234"
        draft.pricePaid = "18,50"
        draft.stars = 4
        draft.notes = "  "
        let kit = try service.create(from: draft)

        #expect(kit.brand == "Italeri")
        #expect(kit.link?.absoluteString == "https://scalemates.com/kits/italeri-1234")
        #expect(kit.pricePaid == Decimal(string: "18.5"))
        #expect(kit.stars == 4)
        #expect(kit.notes == nil)
        #expect(kit.isOwned && kit.status == .bnib)
        #expect(KitDraft(kit: kit).pricePaid == "18.50")
    }

    @Test func refusesKitsWithoutABrandOrNameOrWithBadValues() throws {
        #expect(throws: KitError.blankBrand) { try service.create(from: draft("", "Super Cobra")) }
        #expect(throws: KitError.blankName) { try service.create(from: draft("Italeri", " ")) }
        var badLink = draft()
        badLink.link = "not a link"
        #expect(throws: KitError.invalidLink) { try service.create(from: badLink) }
        var badPrice = draft()
        badPrice.salePrice = "lots"
        #expect(throws: KitError.invalidPrice) { try service.create(from: badPrice) }
        #expect(try context.fetch(FetchDescriptor<Kit>()).isEmpty)
    }

    @Test func editingKeepsAnUnknownStatusUnlessTheUserChangesIt() throws {
        let kit = try service.create(from: draft())
        kit.statusRaw = "painted"
        var edit = KitDraft(kit: kit)
        edit.notes = "Missing decals"
        try service.update(kit, from: edit)
        #expect(kit.statusRaw == "painted")

        edit.status = .built
        try service.update(kit, from: edit)
        #expect(kit.statusRaw == "built")
    }

    @Test func anotherCopySharesTheKitButNotTheBoxsDetails() throws {
        var details = draft()
        details.link = "https://www.scalemates.com/kits/italeri-1234--100"
        details.pricePaid = "20"
        details.stars = 5
        details.isForSale = true
        details.notes = "Opened, bags sealed"
        details.status = .opened
        let kit = try service.create(from: details)

        let copy = try service.addCopy(of: kit)
        #expect(copy.id != kit.id)
        #expect(copy.brand == "Italeri" && copy.number == "1234" && copy.link == kit.link)
        #expect(copy.isOwned && copy.status == .bnib)
        #expect(copy.pricePaid == nil && copy.stars == nil && !copy.isForSale && copy.notes == nil)
        #expect(try service.copies(brand: "Italeri", number: "1234", scale: "1:72", link: nil, excluding: kit) == [copy])
        #expect(kit.isSameKit(as: copy))
    }

    @Test func aSharedPictureIsKeptUntilTheLastCopyIsDeleted() async throws {
        let kit = try service.create(from: draft())
        let image = try Fixtures.writePNG(to: folder.file("box.png"), width: 20, height: 20)
        try await service.setPicture(from: image, on: kit)
        let copy = try service.addCopy(of: kit)
        let path = try #require(kit.picture?.originalRelativePath)
        #expect(copy.picture?.originalRelativePath == path)

        try service.delete([kit])
        #expect(FileManager.default.fileExists(atPath: library.url(forRelativePath: path).path))
        try service.delete([copy])
        #expect(!FileManager.default.fileExists(atPath: library.url(forRelativePath: path).path))
        #expect(try context.fetch(FetchDescriptor<ManagedAsset>()).isEmpty)
    }

    @Test func aPictureMustBeAnImage() async throws {
        let kit = try service.create(from: draft())
        let pdf = try Fixtures.writePDF(to: folder.file("instructions.pdf"))
        await #expect(throws: PictureImporter.PictureError.notAnImage("instructions.pdf")) {
            try await service.setPicture(from: pdf, on: kit)
        }
        #expect(try context.fetch(FetchDescriptor<ManagedAsset>()).isEmpty)
        #expect(kit.picture == nil)
    }

    @Test func settingSeveralKitsAtOnce() throws {
        var forSale = draft()
        forSale.isForSale = true
        forSale.salePrice = "30"
        let first = try service.create(from: forSale)
        let second = try service.create(from: draft("Revell", "Spitfire"))

        try service.setStatus(.wip, for: [first, second])
        #expect(first.status == .wip && second.status == .wip)
        try service.setOwned(false, for: [second])
        #expect(!second.isOwned)
        try service.setForSale(false, for: [first])
        #expect(!first.isForSale)
        #expect(first.salePrice == 30)
    }

    @Test func filters() throws {
        let owned = try service.create(from: draft())
        var wanted = draft("Revell", "Spitfire")
        wanted.isOwned = false
        wanted.scale = "1:48"
        let notOwned = try service.create(from: wanted)
        try service.setStatus(.built, for: [owned, notOwned])
        try service.setForSale(true, for: [owned])

        let kits = [owned, notOwned]
        #expect(kits.filter(KitFilter(ownership: .notOwned).includes) == [notOwned])
        #expect(kits.filter(KitFilter(ownership: .forSale).includes) == [owned])
        // Only owned kits have a status.
        #expect(kits.filter(KitFilter(status: .built).includes) == [owned])
        #expect(kits.filter(KitFilter(brand: "revell").includes) == [notOwned])
        #expect(kits.filter(KitFilter(scale: PaintIdentity.words("1:48")).includes) == [notOwned])
    }

    @Test func sortKeysPutEmptyValuesLast() {
        let rated = Kit(brand: "A", name: "A")
        rated.stars = 5
        let unrated = Kit(brand: "B", name: "B")
        let wanted = Kit(brand: "C", name: "C", isOwned: false)
        #expect(rated.ratingSortKey < unrated.ratingSortKey)
        #expect(rated.statusSortKey < wanted.statusSortKey)
        rated.pricePaid = 10
        #expect(rated.pricePaidSortKey < unrated.pricePaidSortKey)
    }
}

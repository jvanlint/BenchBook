import Testing
@testable import BenchBook

struct PaintFilterTests {
    @Test func groupsBrandsIgnoringCaseAndSpacing() {
        let options = PaintFilterOption.options(for: ["Tamiya", "tamiya ", "Tamiya", "Mr. Hobby", "", "  "])
        #expect(options.map(\.name) == ["Mr. Hobby", "Tamiya"])
        #expect(options.map(\.count) == [1, 3])
        #expect(options.last?.key == "tamiya")
    }

    @Test func filtersByBrandRangeAndOwnership() {
        var filter = PaintFilter()
        #expect(!filter.isActive)
        #expect(filter.includes(brand: "Tamiya", range: "XF", isOwned: false))

        filter.brand = "tamiya"
        #expect(filter.includes(brand: " TAMIYA", range: "XF", isOwned: false))
        #expect(!filter.includes(brand: "Vallejo", range: "Model Air", isOwned: true))

        filter.range = "lp lacquer"
        #expect(filter.includes(brand: "Tamiya", range: "LP  Lacquer", isOwned: false))
        #expect(!filter.includes(brand: "Tamiya", range: "XF", isOwned: false))

        filter.ownedOnly = true
        #expect(!filter.includes(brand: "Tamiya", range: "LP Lacquer", isOwned: false))
        #expect(filter.includes(brand: "Tamiya", range: "LP Lacquer", isOwned: true))

        // A range alone matches it in any brand.
        #expect(PaintFilter(range: "acrylic").includes(brand: "AK", range: "Acrylic", isOwned: false))
    }
}

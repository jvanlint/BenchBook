import Testing
@testable import BenchBook

struct TileHighlightTests {
    @Test func everySelectedTileMatchesTheGallery() {
        // Selected tiles are all accent while the gallery is active, all grey otherwise.
        #expect(TileHighlight(isSelected: true, galleryIsActive: true) == .emphasized)
        #expect(TileHighlight(isSelected: true, galleryIsActive: false) == .unemphasized)
        #expect(TileHighlight(isSelected: false, galleryIsActive: true) == TileHighlight.none)
        #expect(TileHighlight(isSelected: false, galleryIsActive: false) == TileHighlight.none)
    }
}

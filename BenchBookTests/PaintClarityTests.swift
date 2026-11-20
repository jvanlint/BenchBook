import Testing
@testable import BenchBook

struct PaintClarityTests {
    @Test(arguments: ["Clear", "Flat clear", "Semi gloss clear", "Pearl clear", "Clear red", "CLEAR BLUE",
                      "Semi-Gloss Super Clear", "Super Clear Gray Tone", "Clear-Orange"])
    func clearsAreFoundByName(name: String) {
        #expect(PaintClarity.isClear(name: name))
    }

    @Test(arguments: ["Unclear", "Clearcoat", "Flat White", "Dark Sea Grey", ""])
    func otherPaintsArent(name: String) {
        #expect(!PaintClarity.isClear(name: name))
    }
}

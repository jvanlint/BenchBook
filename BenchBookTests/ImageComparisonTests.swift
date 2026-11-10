import Foundation
import Testing
@testable import BenchBook

struct ImageComparisonTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func comparesTwoToFourImages() {
        #expect(!ImageComparison.canCompare(1))
        #expect(ImageComparison.canCompare(2))
        #expect(ImageComparison.canCompare(4))
        #expect(!ImageComparison.canCompare(5))
    }

    @Test func arrangesByCount() {
        #expect(ImageComparison.defaultArrangement(for: 2) == .row)
        #expect(ImageComparison.defaultArrangement(for: 3) == .row)
        #expect(ImageComparison.defaultArrangement(for: 4) == .grid)

        #expect(ImageComparison.rows(count: 3, arrangement: .row) == [[0, 1, 2]])
        // Two in a grid are stacked; three are two above one.
        #expect(ImageComparison.rows(count: 2, arrangement: .grid) == [[0], [1]])
        #expect(ImageComparison.rows(count: 3, arrangement: .grid) == [[0, 1], [2]])
        #expect(ImageComparison.rows(count: 4, arrangement: .grid) == [[0, 1], [2, 3]])
        #expect(ImageComparison.rows(count: 1, arrangement: .grid) == [[0]])
        #expect(ImageComparison.rows(count: 0, arrangement: .row).isEmpty)
    }

    @Test func addsWithoutRepeatsUpToFour() {
        #expect(ImageComparison.adding([c, a], to: [a, b]) == [a, b, c])
        #expect(ImageComparison.adding([c, d, e], to: [a, b]) == [a, b, c, d])
        #expect(ImageComparison.adding([e], to: [a, b, c, d]) == [a, b, c, d])
    }

    @Test func replacesInPlace() {
        #expect(ImageComparison.replacing(b, with: [c], in: [a, b]) == [a, c])
        // The rest of a multi-image drop is added after.
        #expect(ImageComparison.replacing(a, with: [c, d], in: [a, b]) == [c, b, d])
        // An image already shown swaps places.
        #expect(ImageComparison.replacing(a, with: [b], in: [a, b, c]) == [b, a, c])
        #expect(ImageComparison.replacing(e, with: [c], in: [a, b]) == [a, b])
        #expect(ImageComparison.replacing(a, with: [], in: [a, b]) == [a, b])
    }

    @Test func stepsPastImagesAlreadyShown() {
        let siblings = [a, b, c, d, e]
        #expect(ImageComparison.neighbour(of: a, offset: 1, in: siblings, skipping: [a, b]) == c)
        #expect(ImageComparison.neighbour(of: d, offset: -1, in: siblings, skipping: [d, c]) == b)
        #expect(ImageComparison.neighbour(of: e, offset: 1, in: siblings, skipping: [e]) == nil)
        #expect(ImageComparison.neighbour(of: b, offset: -1, in: siblings, skipping: [b, a]) == nil)
        #expect(ImageComparison.neighbour(of: UUID(), offset: 1, in: siblings, skipping: []) == nil)
    }
}

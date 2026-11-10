import CoreGraphics
import Foundation
import Testing
@testable import BenchBook

struct SelectionRectangleTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// Two rows of two 100 × 100 tiles, 20 apart.
    private var frames: [UUID: CGRect] {
        [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 120, y: 0, width: 100, height: 100),
            c: CGRect(x: 0, y: 120, width: 100, height: 100),
            d: CGRect(x: 120, y: 120, width: 100, height: 100),
        ]
    }

    @Test func modeFollowsModifiers() {
        #expect(SelectionRectangle.Mode(command: false, shift: false) == .replace)
        #expect(SelectionRectangle.Mode(command: false, shift: true) == .add)
        #expect(SelectionRectangle.Mode(command: true, shift: false) == .toggle)
        #expect(SelectionRectangle.Mode(command: true, shift: true) == .toggle)
    }

    @Test func rectWorksInAnyDirection() {
        let expected = CGRect(x: 10, y: 20, width: 40, height: 60)
        #expect(SelectionRectangle.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 80)) == expected)
        #expect(SelectionRectangle.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20)) == expected)
    }

    @Test func selectsTilesTouched() {
        let ids = [a, b, c, d]
        // Across the gap between the columns, touching only the top row.
        #expect(SelectionRectangle.hits(CGRect(x: 90, y: 10, width: 40, height: 20), frames: frames, among: ids) == [a, b])
        // In the gutter between all four tiles.
        #expect(SelectionRectangle.hits(CGRect(x: 105, y: 105, width: 10, height: 10), frames: frames, among: ids).isEmpty)
        // A flat line still crosses tiles.
        #expect(SelectionRectangle.hits(CGRect(x: -10, y: 150, width: 300, height: 0), frames: frames, among: ids) == [c, d])
        // Tiles filtered out, or not yet measured, aren't selected.
        #expect(SelectionRectangle.hits(CGRect(x: 0, y: 0, width: 300, height: 300), frames: frames, among: [a, b, UUID()]) == [a, b])
    }

    @Test func combinesWithTheEarlierSelection() {
        #expect(SelectionRectangle.selection(base: [a, b], hits: [b, c], mode: .replace) == [b, c])
        #expect(SelectionRectangle.selection(base: [a, b], hits: [b, c], mode: .add) == [a, b, c])
        #expect(SelectionRectangle.selection(base: [a, b], hits: [b, c], mode: .toggle) == [a, c])
    }

    @Test func scrollsNearTheEdges() {
        #expect(SelectionRectangle.autoscrollStep(pointerY: 300, visibleMinY: 100, visibleMaxY: 600) == 0)
        #expect(SelectionRectangle.autoscrollStep(pointerY: 595, visibleMinY: 100, visibleMaxY: 600) > 0)
        #expect(SelectionRectangle.autoscrollStep(pointerY: 105, visibleMinY: 100, visibleMaxY: 600) < 0)
        // Faster further out, up to a limit.
        let near = SelectionRectangle.autoscrollStep(pointerY: 610, visibleMinY: 100, visibleMaxY: 600)
        let far = SelectionRectangle.autoscrollStep(pointerY: 700, visibleMinY: 100, visibleMaxY: 600)
        #expect(far > near)
        #expect(SelectionRectangle.autoscrollStep(pointerY: 5_000, visibleMinY: 100, visibleMaxY: 600) == 40)
    }
}

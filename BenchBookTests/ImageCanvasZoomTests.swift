import AppKit
import SwiftUI
import Testing
@testable import BenchBook

/// The viewer's opening zoom, in a real window.
@MainActor
struct ImageCanvasZoomTests {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Shows a 4000 × 3000 image in a 600 × 400 window and returns the zoom.
    private func openingZoom(actualSize: Bool) async throws -> (percent: Int, fitting: Bool) {
        let controller = ImageCanvasController()
        controller.opensAtActualSize = { actualSize }
        let canvas = ImageCanvas(image: image(width: 4000, height: 3000), notes: [], selection: .constant(nil),
                                 controller: controller, onCreate: { _ in }, onMove: { _, _ in }, onDelete: { _ in })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: canvas.frame(width: 600, height: 400))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        defer { window.close() }
        return (controller.zoomPercent, controller.isFitting)
    }

    @Test func opensFittedByDefault() async throws {
        let zoom = try await openingZoom(actualSize: false)
        #expect(zoom.fitting)
        #expect(zoom.percent < 100)
    }

    @Test func opensAtActualSizeWhenSet() async throws {
        let zoom = try await openingZoom(actualSize: true)
        #expect(!zoom.fitting)
        #expect(zoom.percent == 100)
    }
}

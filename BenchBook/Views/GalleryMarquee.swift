import AppKit
import SwiftUI

/// What rectangle selection needs between updates. Not observed, so tiles
/// appearing and the gallery scrolling don't redraw it.
final class GalleryMarquee {
    struct Drag {
        let start: CGPoint
        /// The selection when the drag began.
        let base: Set<UUID>
        let mode: SelectionRectangle.Mode
        var pointerX: CGFloat
        /// From the top of the visible area, so auto-scrolling moves the point.
        var pointerYInView: CGFloat
        var isCancelled = false
    }

    /// Tile frames in grid coordinates.
    var frames: [UUID: CGRect] = [:]
    var onScreen = Set<UUID>()
    var scroll: ScrollGeometry?
    var drag: Drag?
    var keyMonitor: Any?
    var autoscroll: Task<Void, Never>?
    /// The AppKit view behind the gallery, for telling where clicks land.
    weak var galleryView: NSView?
    var clickMonitor: Any?
    var deleteMonitor: Any?

    func stopWatchingClicks() {
        for monitor in [clickMonitor, deleteMonitor].compactMap(\.self) { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        deleteMonitor = nil
    }

    func forgetOffscreenFrames() {
        frames = frames.filter { onScreen.contains($0.key) }
    }

    /// Ends auto-scrolling and stops watching for Esc.
    func stop() {
        autoscroll?.cancel()
        autoscroll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Hands over the AppKit view it's placed behind, once it's in a window.
struct ViewAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

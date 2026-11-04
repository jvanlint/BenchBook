import AppKit
import SwiftUI

/// A note box as the canvas draws it, in image pixels.
struct NoteBox: Equatable {
    let id: UUID
    var rect: CGRect
    let number: Int
}

/// Lets SwiftUI controls drive the canvas (zoom, draw mode) and shows the zoom level.
@Observable
final class ImageCanvasController {
    /// 100% means one image pixel per screen pixel.
    private(set) var zoomPercent = 100
    var isDrawing = false
    /// While true, the image refits whenever the window resizes.
    private(set) var isFitting = true

    @ObservationIgnored fileprivate weak var scrollView: NSScrollView?

    static let minimumMagnification: CGFloat = 0.02
    static let maximumMagnification: CGFloat = 16

    func zoomIn() { zoom(by: 1.5) }
    func zoomOut() { zoom(by: 1 / 1.5) }

    func zoomToFit() {
        isFitting = true
        fit()
    }

    func actualSize() {
        guard let scrollView else { return }
        isFitting = false
        setMagnification(1 / backingScale(of: scrollView), in: scrollView)
    }

    /// Zooms so the box (image pixels) fills most of the view, centred.
    func zoom(toPixelRect rect: CGRect) {
        guard let scrollView, let document = scrollView.documentView else { return }
        isFitting = false
        let margin = max(rect.width, rect.height, 80) * 0.5
        let target = rect.insetBy(dx: -margin, dy: -margin).intersection(document.bounds)
        scrollView.magnify(toFit: target.isEmpty ? rect : target)
        if scrollView.magnification > Self.maximumMagnification {
            setMagnification(Self.maximumMagnification, in: scrollView)
        }
        updateZoomPercent()
    }

    fileprivate func fit() {
        guard let scrollView, let document = scrollView.documentView,
              document.bounds.width > 0, document.bounds.height > 0
        else { return }
        let available = scrollView.contentSize
        let scale = min(available.width / document.bounds.width, available.height / document.bounds.height)
        scrollView.magnification = clamp(scale)
        updateZoomPercent()
    }

    fileprivate func userDidZoom() {
        isFitting = false
        updateZoomPercent()
    }

    /// Zooms keeping `point` (document coordinates) under the pointer.
    fileprivate func zoom(by factor: CGFloat, around point: CGPoint) {
        guard let scrollView else { return }
        isFitting = false
        scrollView.setMagnification(clamp(scrollView.magnification * factor), centeredAt: point)
        updateZoomPercent()
    }

    private func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        isFitting = false
        setMagnification(scrollView.magnification * factor, in: scrollView)
    }

    private func setMagnification(_ value: CGFloat, in scrollView: NSScrollView) {
        let center = CGPoint(x: scrollView.documentVisibleRect.midX, y: scrollView.documentVisibleRect.midY)
        scrollView.setMagnification(clamp(value), centeredAt: center)
        updateZoomPercent()
    }

    fileprivate func updateZoomPercent() {
        guard let scrollView else { return }
        zoomPercent = Int((scrollView.magnification * backingScale(of: scrollView) * 100).rounded())
        (scrollView.documentView as? CanvasDocumentView)?.overlay.needsDisplay = true
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minimumMagnification), Self.maximumMagnification)
    }

    private func backingScale(of view: NSView) -> CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

/// The zoomable, pannable image with its note boxes.
struct ImageCanvas: NSViewRepresentable {
    let image: CGImage
    let notes: [NoteBox]
    /// When false the image is shown clean and boxes can't be clicked.
    var showsBoxes = true
    @Binding var selection: UUID?
    let controller: ImageCanvasController
    var onCreate: (CGRect) -> Void
    var onMove: (UUID, CGRect) -> Void
    var onDelete: (UUID) -> Void

    final class Coordinator {
        var magnifyObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.magnifyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = FittingScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ImageCanvasController.minimumMagnification
        scrollView.maxMagnification = ImageCanvasController.maximumMagnification
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.controller = controller

        let document = CanvasDocumentView(image: image)
        scrollView.documentView = document
        controller.scrollView = scrollView

        context.coordinator.magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.userDidZoom() }
        }
        update(document.overlay)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let document = scrollView.documentView as? CanvasDocumentView else { return }
        if document.image !== image {
            document.setImage(image)
            controller.zoomToFit()
        }
        update(document.overlay)
    }

    private func update(_ overlay: NoteOverlayView) {
        overlay.notes = notes
        overlay.showsBoxes = showsBoxes
        overlay.selectedID = selection
        overlay.isDrawing = controller.isDrawing
        overlay.onSelect = { id in selection = id }
        overlay.onCreate = onCreate
        overlay.onMove = onMove
        overlay.onDelete = onDelete
        overlay.onFinishDrawing = { controller.isDrawing = false }
    }
}

// MARK: - AppKit views

/// Refits the image on resize while the controller is in fit mode. A mouse
/// scroll wheel zooms and a middle-click zooms to fit; trackpad scrolling
/// still pans.
private final class FittingScrollView: NSScrollView {
    weak var controller: ImageCanvasController?
    private var lastSize: CGSize = .zero

    override func scrollWheel(with event: NSEvent) {
        // ⌘-scroll zooms on any device, including trackpads and Magic Mouse.
        let zooms = Self.isMouseWheel(event) || event.modifierFlags.contains(.command)
        guard zooms, event.scrollingDeltaY != 0, let controller, let documentView else {
            super.scrollWheel(with: event)
            return
        }
        // Wheel away from you zooms in, whatever the natural scrolling setting.
        let physical = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // Smooth-scrolling mice report points, not notches; ~20 points ≈ one notch.
        let steps = event.hasPreciseScrollingDeltas ? physical / 20 : physical
        let notches = min(max(steps, -5), 5)
        let point = documentView.convert(event.locationInWindow, from: nil)
        controller.zoom(by: pow(1.15, notches), around: point)
    }

    /// Trackpads and Magic Mouse send touch gestures with a scroll phase and
    /// keep panning. Wheel mice, including smooth-scrolling ones such as
    /// Logitech mice with Logi Options+, send no phase and zoom.
    static func isMouseWheel(_ event: NSEvent) -> Bool {
        event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            controller?.zoomToFit()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        if contentSize != lastSize {
            lastSize = contentSize
            if controller?.isFitting == true {
                controller?.fit()
            }
        }
    }
}

/// Keeps the image centred when it's smaller than the window.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Sized to the image in pixels; the scroll view's magnification does the zooming.
private final class CanvasDocumentView: NSView {
    private(set) var image: CGImage
    private let imageView = ImageLayerView()
    let overlay = NoteOverlayView()

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.imageSize = bounds.size
        addSubview(imageView)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setImage(_ newImage: CGImage) {
        image = newImage
        setFrameSize(CGSize(width: newImage.width, height: newImage.height))
        imageView.image = newImage
        overlay.imageSize = bounds.size
    }
}

/// Shows the image as layer contents, so zooming and panning are GPU-smooth.
private final class ImageLayerView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws note boxes and handles drawing, selecting, moving, resizing and panning.
final class NoteOverlayView: NSView {
    var notes: [NoteBox] = [] { didSet { if notes != oldValue { needsDisplay = true } } }
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            needsDisplay = true
            // Bring a note chosen in the side panel into view.
            if let rect = visibleNotes.first(where: { $0.id == selectedID })?.rect, !visibleRect.contains(rect) {
                scrollToVisible(rect.insetBy(dx: -40 / magnification, dy: -40 / magnification))
            }
        }
    }
    var isDrawing = false {
        didSet {
            if isDrawing != oldValue {
                window?.invalidateCursorRects(for: self)
                if isDrawing { window?.makeFirstResponder(self) }
            }
        }
    }
    var imageSize: CGSize = .zero
    var showsBoxes = true {
        didSet {
            if showsBoxes != oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// Boxes that can be seen and clicked.
    private var visibleNotes: [NoteBox] {
        showsBoxes ? notes : []
    }

    var onSelect: (UUID?) -> Void = { _ in }
    var onCreate: (CGRect) -> Void = { _ in }
    var onMove: (UUID, CGRect) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onFinishDrawing: () -> Void = {}

    private enum Drag {
        case creating(start: CGPoint, current: CGPoint)
        case moving(id: UUID, start: CGPoint, original: CGRect, current: CGRect)
        case resizing(id: UUID, handle: NoteGeometry.Handle, current: CGRect)
        case panning(start: CGPoint, origin: CGPoint)
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat {
        enclosingScrollView?.magnification ?? 1
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let scale = 1 / magnification
        for note in visibleNotes {
            draw(note, rect: liveRect(for: note), selected: note.id == selectedID, scale: scale)
        }
        if case .creating(let start, let current) = drag {
            let rect = NoteGeometry.rect(from: start, to: current, in: imageSize)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2 * scale
            path.setLineDash([6 * scale, 4 * scale], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func draw(_ note: NoteBox, rect: CGRect, selected: Bool, scale: CGFloat) {
        let color: NSColor = selected ? .controlAccentColor : .systemYellow

        // A dark halo keeps boxes visible on bright skies and pale paint.
        let halo = NSBezierPath(rect: rect)
        halo.lineWidth = 4 * scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        halo.stroke()

        if selected {
            color.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: rect).fill()
        }
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2 * scale
        color.setStroke()
        outline.stroke()

        // Number badge at the top-left corner.
        let diameter = 22 * scale
        let badge = CGRect(x: rect.minX - diameter / 3, y: rect.minY - diameter / 3, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let text = NSAttributedString(string: "\(note.number)", attributes: [
            .font: NSFont.systemFont(ofSize: 12 * scale, weight: .bold),
            .foregroundColor: selected ? NSColor.white : NSColor.black,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))

        if selected {
            let side = 8 * scale
            for handle in NoteGeometry.Handle.allCases {
                let p = NoteGeometry.point(of: handle, in: rect)
                let square = NSBezierPath(rect: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
                NSColor.white.setFill()
                square.fill()
                square.lineWidth = 1.5 * scale
                color.setStroke()
                square.stroke()
            }
        }
    }

    private func liveRect(for note: NoteBox) -> CGRect {
        switch drag {
        case .moving(let id, _, _, let current) where id == note.id: current
        case .resizing(let id, _, let current) where id == note.id: current
        default: note.rect
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if isDrawing {
            drag = .creating(start: point, current: point)
            return
        }
        let tolerance = 8 / magnification
        if let selected = visibleNotes.first(where: { $0.id == selectedID }),
           let handle = NoteGeometry.handle(at: point, in: selected.rect, tolerance: tolerance) {
            drag = .resizing(id: selected.id, handle: handle, current: selected.rect)
            return
        }
        if let hit = visibleNotes.last(where: { $0.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) }) {
            onSelect(hit.id)
            drag = .moving(id: hit.id, start: point, original: hit.rect, current: hit.rect)
            return
        }
        onSelect(nil)
        if let clip = enclosingScrollView?.contentView {
            drag = .panning(start: event.locationInWindow, origin: clip.bounds.origin)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .creating(let start, _):
            drag = .creating(start: start, current: point)
        case .moving(let id, let start, let original, _):
            let moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            drag = .moving(id: id, start: start, original: original, current: NoteGeometry.clamp(moved, to: imageSize))
        case .resizing(let id, let handle, let current):
            let original = notes.first { $0.id == id }?.rect ?? current
            drag = .resizing(id: id, handle: handle, current: NoteGeometry.resize(original, moving: handle, to: point, in: imageSize))
        case .panning(let start, let origin):
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let dx = (event.locationInWindow.x - start.x) / magnification
            let dy = (event.locationInWindow.y - start.y) / magnification
            let proposed = CGRect(origin: CGPoint(x: origin.x - dx, y: origin.y + dy), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scrollView.reflectScrolledClipView(clip)
            return
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        switch drag {
        case .creating(let start, let current):
            let rect = NoteGeometry.rect(from: start, to: current, in: imageSize)
            if NoteGeometry.isLargeEnough(rect) {
                onCreate(rect)
                onFinishDrawing()
            }
        case .moving(let id, _, let original, let current) where current != original:
            onMove(id, current)
        case .resizing(let id, _, let current):
            if NoteGeometry.isLargeEnough(current), current != notes.first(where: { $0.id == id })?.rect {
                onMove(id, current)
            }
        case .panning:
            NSCursor.pop()
        default:
            break
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        enclosingScrollView?.otherMouseDown(with: event)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if let selectedID, showsBoxes { onDelete(selectedID) } else { super.keyDown(with: event) }
        case 53: // Escape
            if isDrawing { onFinishDrawing() } else if selectedID != nil { onSelect(nil) } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        if isDrawing {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .openHand)
            for note in visibleNotes {
                addCursorRect(note.rect, cursor: .arrow)
            }
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        String(localized: "Image with \(notes.count) notes. The notes are listed in the side panel.")
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Photos from an iPhone or iPad camera (Continuity Camera), offered in
/// File › Import from iPhone or iPad.
///
/// SwiftUI's `importsItemProviders` makes the menu items available, but when
/// the photo arrives SwiftUI no longer accepts it, and AppKit reports
/// "Cocoa error 66563". So the photo is taken by `CameraReceiverView`, an
/// invisible AppKit view that becomes the window's first responder when a
/// camera item is chosen, as Apple's AppKit guide describes. The item runs
/// until the photo arrives or is cancelled, so focus moves just before it
/// runs and comes back once it has.
enum ContinuityCamera {
    /// SwiftUI matches these exactly, so `.image` alone offers nothing. A
    /// document scan arrives as a PDF, which isn't a photo.
    static let types: [UTType] = [.jpeg, .heic, .png, .tiff]

    /// True for a photo type, including AppKit's old name for TIFF.
    static func takes(_ returnType: NSPasteboard.PasteboardType?) -> Bool {
        guard let raw = returnType?.rawValue else { return false }
        if raw == "NeXT TIFF v4.0 pasteboard type" { return true }
        guard let type = UTType(raw) else { return false }
        return type.conforms(to: .image)
    }

    /// The camera's photos have no name of their own.
    static func named(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        for provider in providers {
            provider.suggestedName = String(localized: "Camera Photo")
        }
        return providers
    }
}

extension View {
    /// Takes photos from the iPhone or iPad camera while this view is in the
    /// key window.
    func takesCameraPhotos(_ action: @escaping ([NSItemProvider]) -> Void) -> some View {
        importsItemProviders(ContinuityCamera.types) { providers in
            action(ContinuityCamera.named(providers))
            return true
        }
        .background(CameraReceiver(action: action))
    }
}

private struct CameraReceiver: NSViewRepresentable {
    let action: ([NSItemProvider]) -> Void

    func makeNSView(context: Context) -> CameraReceiverView {
        let view = CameraReceiverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CameraReceiverView, context: Context) {
        view.action = action
    }
}

/// Takes the camera's photo for the view it sits behind. It draws nothing and
/// takes no clicks; it only holds focus while a photo is on its way.
final class CameraReceiverView: NSView, NSServicesMenuRequestor {
    var action: (([NSItemProvider]) -> Void)?
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.watchCameraMenu() }
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, ContinuityCamera.takes(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let providers = PasteRouter.providers(from: pasteboard)
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard let action, !providers.isEmpty else { return false }
        action(ContinuityCamera.named(providers))
        return true
    }

    /// Becomes first responder, so the photo comes here when it arrives.
    func takeFocusForPhoto() {
        guard let window, window.firstResponder !== self else { return }
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
    }

    private func giveBackFocus() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(previousResponder)
    }

    // MARK: Camera menu

    private static var isWatching = false
    private static weak var waiting: CameraReceiverView?

    /// When a camera item under File › Import from iPhone or iPad is chosen,
    /// the receiver in the key window takes focus until the item finishes.
    private static func watchCameraMenu() {
        guard !isWatching else { return }
        isWatching = true
        NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let item = note.userInfo?["MenuItem"] as? NSMenuItem, isCameraItem(item),
                      let content = NSApp.keyWindow?.contentView, let receiver = receiver(in: content) else { return }
                receiver.takeFocusForPhoto()
                waiting = receiver
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let item = note.userInfo?["MenuItem"] as? NSMenuItem, isCameraItem(item) else { return }
                waiting?.giveBackFocus()
                waiting = nil
            }
        }
    }

    private static func isCameraItem(_ item: NSMenuItem) -> Bool {
        var current: NSMenuItem? = item
        while let menuItem = current {
            if menuItem.identifier == NSMenuItem.importFromDeviceIdentifier { return true }
            current = menuItem.parent
        }
        return false
    }

    private static func receiver(in view: NSView) -> CameraReceiverView? {
        if let receiver = view as? CameraReceiverView { return receiver }
        for subview in view.subviews {
            if let receiver = receiver(in: subview) { return receiver }
        }
        return nil
    }
}

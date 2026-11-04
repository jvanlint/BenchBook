import AppKit
import UniformTypeIdentifiers

/// Handles Edit → Paste (⌘V) for References.
///
/// AppKit sends Paste to the focused view first, so text fields keep normal
/// pasting. When nothing focused handles it, which is the case for the
/// sidebar, the grid and empty space, it reaches the app delegate and then
/// this router. That works no matter where SwiftUI's focus is.
final class PasteRouter {
    static let shared = PasteRouter()

    /// Types that can become References; mirrors drag and drop.
    static let supportedTypes: [UTType] = [.fileURL, .image, .pdf, .url, .plainText]

    private var owner: UUID?
    private var handler: (([NSItemProvider]) -> Void)?

    /// Makes `handler` the paste destination. The workspace in the front
    /// window registers itself; the most recent registration wins.
    func register(owner: UUID, handler: @escaping ([NSItemProvider]) -> Void) {
        self.owner = owner
        self.handler = handler
    }

    /// Clears the destination, but only if `owner` still holds it.
    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
    }

    var hasDestination: Bool {
        handler != nil
    }

    var canPaste: Bool {
        handler != nil && Self.hasSupportedContent(NSPasteboard.general)
    }

    func paste() {
        guard let handler else { return }
        let providers = Self.providers(from: NSPasteboard.general)
        if !providers.isEmpty {
            handler(providers)
        }
    }

    static func hasSupportedContent(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: supportedTypes.map(\.identifier))
    }

    /// One provider per pasteboard item, offering every type the item has.
    /// The data is copied now, so later clipboard changes don't affect it.
    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let provider = NSItemProvider()
            var registered = false
            for type in item.types {
                guard UTType(type.rawValue) != nil, let data = item.data(forType: type) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                registered = true
            }
            return registered ? provider : nil
        }
    }
}

/// Receives Paste when no focused view handles it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    @objc func paste(_ sender: Any?) {
        PasteRouter.shared.paste()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return PasteRouter.shared.canPaste
        }
        return true
    }
}

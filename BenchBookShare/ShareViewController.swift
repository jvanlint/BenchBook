import AppKit
import SwiftUI

/// Entry point for the "BenchBook" item in the macOS Share menu.
final class ShareViewController: NSViewController {
    private var model: ShareModel?

    override func loadView() {
        let model = ShareModel(
            extensionItems: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            finish: { [weak self] sent in self?.finish(sent: sent) }
        )
        self.model = model
        let hosting = NSHostingView(rootView: ShareView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        view = hosting
        preferredContentSize = hosting.fittingSize
    }

    private func finish(sent: Bool) {
        if sent {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}

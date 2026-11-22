import AppKit
import Foundation
import SafariServices

/// Answers `browser.runtime.sendNativeMessage` from the Safari extension's
/// JavaScript. Captures go to BenchBook through the App Group inbox, as the
/// Share extension's do; this extension never writes to the library.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let request = Request(message: item?.userInfo?[SFExtensionMessageKey])

        Task {
            let reply = await Self.reply(to: request)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply.value ?? NSNull()]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private static func reply(to request: Request) async -> Request {
        guard let inboxURL = AppGroup.inboxURL, let resultsURL = AppGroup.resultsURL else {
            return Request(message: [
                "ok": false,
                "error": String(localized: "BenchBook's shared folder isn't available. Open BenchBook once, then try again."),
            ])
        }
        let service = SafariCaptureService(
            inbox: CaptureInboxStore(inboxURL: inboxURL),
            results: CaptureResultStore(resultsURL: resultsURL),
            directory: AppGroup.defaults.map(ProjectDirectory.init),
            launchApp: { Task { @MainActor in launchBenchBookInBackground() } }
        )
        return Request(message: await service.respond(to: request.value))
    }

    /// Opens BenchBook without bringing it forward, so it imports straight away.
    private static func launchBenchBookInBackground() {
        // .../BenchBook.app/Contents/PlugIns/BenchBookSafari.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

/// A property-list message passed between Safari and this extension. It's
/// only read, never changed, so it's safe to pass between tasks.
private struct Request: @unchecked Sendable {
    let value: Any?

    init(message: Any?) {
        value = message
    }
}

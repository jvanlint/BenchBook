import AppKit
import OSLog
import UniformTypeIdentifiers

/// What the window accepts from drags, and how a drop is read.
enum CaptureDrop {
    static let types = PasteRouter.supportedTypes

    /// Reads a drop straight from the drag pasteboard, copying its data now.
    ///
    /// Browsers such as Safari supply drag data lazily and offer the original
    /// file only as a promise, which SwiftUI's item providers don't deliver
    /// reliably. Reading the pasteboard during the drop avoids that. Falls
    /// back to SwiftUI's providers if the pasteboard has nothing usable.
    static func providers(fallback: [NSItemProvider], pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> [NSItemProvider] {
        let snapshot = PasteRouter.providers(from: pasteboard)
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        Logger.capture.debug("Drop types: \(pasteboard.types?.map(\.rawValue) ?? [], privacy: .public); promises: \(receivers.count)")

        guard !snapshot.isEmpty || !receivers.isEmpty else { return fallback }

        // A promise is usually the original file (e.g. the JPEG), so offer it
        // first, on the provider for the same item so it keeps the web address.
        var providers = snapshot
        for (index, receiver) in receivers.enumerated() {
            guard let type = receiver.fileTypes.compactMap(UTType.init).first(where: { type in
                ItemProviderReader.fileTypes.contains { type.conforms(to: $0) }
            }) else { continue }
            let promise = PromisedFile(receiver: receiver)
            let provider = receivers.count == snapshot.count ? snapshot[index] : NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                promise.wait { url in
                    completion(url, false, url == nil ? CocoaError(.fileReadUnknown) : nil)
                }
                return nil
            }
            if receivers.count != snapshot.count { providers.append(provider) }
        }
        return providers
    }
}

/// A file promised by a drag source, requested as soon as the drop lands.
nonisolated final class PromisedFile: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var url: URL?
    private var waiters: [(URL?) -> Void] = []

    init(receiver: NSFilePromiseReceiver, timeout: TimeInterval = 60) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "BenchBook-Promised-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: OperationQueue()) { [self] url, error in
            if let error {
                Logger.capture.error("Promised file failed: \(error.localizedDescription, privacy: .public)")
            }
            finish(error == nil ? url : nil)
        }
        // Don't wait forever on a source that never delivers.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
    }

    /// Calls `handler` with the received file, or nil if it didn't arrive.
    func wait(_ handler: @escaping (URL?) -> Void) {
        lock.lock()
        guard isFinished else {
            waiters.append(handler)
            lock.unlock()
            return
        }
        let url = url
        lock.unlock()
        handler(url)
    }

    private func finish(_ received: URL?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        url = received
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0(received) }
    }
}

extension Logger {
    nonisolated static let capture = Logger(subsystem: "com.jasonvanlint.BenchBook", category: "Capture")
}

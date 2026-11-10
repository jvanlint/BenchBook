import AppKit
import SwiftUI

extension View {
    /// Remembers the window's size and position under `name` and restores
    /// them when the window next opens. Unlike system window restoration,
    /// this works even when macOS is set to close windows on quit, and when
    /// running from Xcode.
    func windowFrameAutosave(_ name: String) -> some View {
        background(WindowFrameAutosave(name: name))
    }
}

private struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> WindowFrameAutosaveView {
        WindowFrameAutosaveView(name: name)
    }

    func updateNSView(_ view: WindowFrameAutosaveView, context: Context) {}
}

/// Hooks the window it's placed in and saves its frame in user defaults.
///
/// AppKit's frame autosave name can't be used: SwiftUI replaces it with its
/// own, named after the window's view types, so it changes with the code.
/// SwiftUI also places the window after it's created, so the saved frame is
/// applied on the next pass of the run loop, and saving starts only then.
final class WindowFrameAutosaveView: NSView {
    let name: String
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private weak var trackedWindow: NSWindow?

    init(name: String, defaults: UserDefaults = .standard) {
        self.name = name
        self.defaults = defaults
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var defaultsKey: String { "BenchBook Window Frame \(name)" }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== trackedWindow else { return }
        stopTracking()
        trackedWindow = window
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.trackedWindow else { return }
            self.restoreFrame(of: window)
            self.startSaving(window)
        }
    }

    /// AppKit keeps a restored frame on a connected screen.
    private func restoreFrame(of window: NSWindow) {
        guard let saved = defaults.string(forKey: defaultsKey) else { return }
        window.setFrame(from: saved)
    }

    private func startSaving(_ window: NSWindow) {
        let center = NotificationCenter.default
        for note in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: note, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame(of: window) }
            })
        }
    }

    /// Full screen and minimised frames aren't worth keeping.
    private func saveFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        defaults.set(window.frameDescriptor, forKey: defaultsKey)
    }

    private func stopTracking() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

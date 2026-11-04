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

/// Hooks the window it's placed in. Only one open window can hold a name, so
/// extra windows of the same kind simply keep their default size.
final class WindowFrameAutosaveView: NSView {
    let name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.frameAutosaveName != name else { return }
        // Restore first (AppKit keeps it on a connected screen), then keep saving.
        window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

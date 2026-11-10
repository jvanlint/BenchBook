import AppKit
import Testing
@testable import BenchBook

@MainActor
struct WindowFrameAutosaveTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Lets the view's deferred restore run. Running the run loop from
    /// inside a main-queue job wouldn't drain the main queue.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func savesFrameChangesAndRestoresThemInTheNextWindow() async throws {
        let suite = "BenchBookTests.WindowFrame.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = "Main"

        // First launch: the user resizes and moves the window.
        let first = makeWindow()
        let firstView = WindowFrameAutosaveView(name: name, defaults: defaults)
        first.contentView?.addSubview(firstView)
        try await settle()
        let chosen = NSRect(x: 150, y: 120, width: 900, height: 640)
        first.setFrame(chosen, display: false)
        #expect(defaults.string(forKey: firstView.defaultsKey) != nil)
        first.close()

        // Next launch: the window opens at the default size, then the saved
        // frame is applied after SwiftUI would have placed it.
        let second = makeWindow()
        second.contentView?.addSubview(WindowFrameAutosaveView(name: name, defaults: defaults))
        #expect(second.frame.size != chosen.size)
        try await settle()
        #expect(second.frame.size == chosen.size)
    }

    /// Placing the window at its default frame mustn't overwrite the saved one.
    @Test func initialPlacementIsNotSaved() throws {
        let suite = "BenchBookTests.WindowFrame.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let window = makeWindow()
        let view = WindowFrameAutosaveView(name: "Main", defaults: defaults)
        window.contentView?.addSubview(view)
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 400), display: false)  // as SwiftUI does
        #expect(defaults.string(forKey: view.defaultsKey) == nil)
        window.close()
    }
}

import AppKit
import Testing
@testable import BenchBook

@MainActor
struct WindowFrameAutosaveTests {
    @Test func restoresAndKeepsSavingTheWindowFrame() {
        let name = "BenchBookTests Window \(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        // First launch: the user resizes the window.
        let first = makeWindow()
        first.contentView?.addSubview(WindowFrameAutosaveView(name: name))
        #expect(first.frameAutosaveName == name)
        let resized = NSRect(x: 150, y: 120, width: 900, height: 640)
        first.setFrame(resized, display: false)
        first.saveFrame(usingName: name)
        first.setFrameAutosaveName("")  // as when the window closes

        // Next launch: a new window opens at the saved size.
        let second = makeWindow()
        second.contentView?.addSubview(WindowFrameAutosaveView(name: name))
        #expect(second.frameAutosaveName == name)
        #expect(second.frame.size == resized.size)
    }
}

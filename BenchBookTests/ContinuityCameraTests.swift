import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BenchBook

@MainActor
struct ContinuityCameraTests {
    /// Shows `view` in a window, as SwiftUI only answers once it has drawn.
    private func shown(_ view: some View) async throws -> (NSView, NSWindow) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        return (hosting, window)
    }

    private func answer(_ hosting: NSView, _ type: UTType) -> Any? {
        hosting.validRequestor(forSendType: nil, returnType: NSPasteboard.PasteboardType(type.identifier))
    }

    /// AppKit asks the window's SwiftUI view whether it takes the camera's
    /// photo types. SwiftUI matches types exactly: `.image` takes nothing.
    @Test func aViewTakesPhotosButNotScans() async throws {
        let (hosting, window) = try await shown(Text("Build Photos").takesCameraPhotos { _ in })
        for type in [UTType.jpeg, .heic, .png, .tiff] {
            #expect(answer(hosting, type) != nil, "\(type.identifier)")
        }
        #expect(answer(hosting, .pdf) == nil)
        window.close()

        let (plain, plainWindow) = try await shown(Text("References"))
        #expect(answer(plain, .jpeg) == nil)
        plainWindow.close()
        let (generic, genericWindow) = try await shown(Text("x").importsItemProviders([.image]) { _ in true })
        #expect(answer(generic, .jpeg) == nil)
        genericWindow.close()
    }

    /// The receiver takes the camera's photo types, under any name AppKit
    /// uses, but not a document scan.
    @Test func theReceiverTakesPhotos() throws {
        let receiver = CameraReceiverView()
        var received: [NSItemProvider] = []
        receiver.action = { received = $0 }
        for raw in ["public.jpeg", "public.heic", "public.png", "public.tiff", "NeXT TIFF v4.0 pasteboard type"] {
            #expect(receiver.validRequestor(forSendType: nil, returnType: NSPasteboard.PasteboardType(raw)) as? CameraReceiverView === receiver, "\(raw)")
        }
        #expect(receiver.validRequestor(forSendType: nil, returnType: .pdf) == nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BenchBookTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0xFF, 0xD8, 0xFF]), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        #expect(receiver.readSelection(from: pasteboard))
        let provider = try #require(received.first)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier))
        #expect(provider.suggestedName == "Camera Photo")

        pasteboard.clearContents()
        pasteboard.setData(Data("%PDF-1.7".utf8), forType: .pdf)
        #expect(!receiver.readSelection(from: pasteboard))
    }

    @Test func photosAreNamed() {
        let provider = NSItemProvider()
        #expect(ContinuityCamera.named([provider]).first?.suggestedName == "Camera Photo")
    }
}

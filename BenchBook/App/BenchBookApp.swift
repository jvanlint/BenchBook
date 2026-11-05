import SwiftData
import SwiftUI

@main
struct BenchBookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let library = Result { try LibraryEnvironment() }

    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let library):
                ContentView()
                    .libraryEnvironment(library)
                    .windowFrameAutosave("BenchBook Main Window")
                    .onAppear { library.capture.startInbox() }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        library.capture.processInbox()
                    }
            case .failure(let error):
                LibraryErrorView(error: error)
            }
        }
        .commands {
            SidebarCommands()
            BenchBookCommands()
        }

        // One window per image; reopening an image brings its window forward.
        WindowGroup("Image", id: ImageViewerWindow.id, for: UUID.self) { $referenceID in
            if case .success(let library) = library {
                ImageViewerWindow(referenceID: $referenceID)
                    .libraryEnvironment(library)
            }
        }
        .defaultSize(width: 1100, height: 760)
    }
}

private extension View {
    /// The store and services every window needs.
    func libraryEnvironment(_ library: LibraryEnvironment) -> some View {
        modelContainer(library.container)
            .environment(\.assetLibrary, library.assetLibrary)
            .environment(\.thumbnailStore, library.thumbnails)
            .environment(\.captureCoordinator, library.capture)
            .environment(\.linkInfoService, library.linkInfo)
            .environment(\.searchIndex, library.search)
            .environment(\.projectDirectory, library.projectDirectory)
    }
}

/// Shown if the library can't be opened. The store is left untouched.
private struct LibraryErrorView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open Your Library", systemImage: "exclamationmark.triangle")
        } description: {
            Text("BenchBook didn't change any of your data. Quit and reopen the app to try again.")
            Text(error.localizedDescription)
                .textSelection(.enabled)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

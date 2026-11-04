import SwiftData
import SwiftUI

@main
struct BenchBookApp: App {
    private let container = Result { try PersistenceController.makeContainer() }

    var body: some Scene {
        WindowGroup {
            switch container {
            case .success(let container):
                ContentView()
                    .modelContainer(container)
            case .failure(let error):
                LibraryErrorView(error: error)
            }
        }
        .commands {
            SidebarCommands()
            BenchBookCommands()
        }
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

import AppKit
import SwiftData
import SwiftUI

/// BenchBook › Settings… (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            // Grouped forms don't size the window themselves, so each tab
            // asks for the height its content needs.
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
                    .frame(height: 560)
            }
            Tab("Library", systemImage: "externaldrive") {
                LibrarySettings()
                    .frame(height: 600)
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.fetchesLinkDetailsKey) private var fetchesLinkDetails = true
    @AppStorage(AppSettings.opensImagesAtActualSizeKey) private var opensImagesAtActualSize = false
    @AppStorage(AppSettings.showsNoteBoxesKey) private var showsNoteBoxes = true
    @AppStorage(AppSettings.newProjectStatusKey) private var newProjectStatus = ProjectStatus.researching
    @AppStorage(AppSettings.suggestsImageDetailsKey) private var suggestsImageDetails = false
    @Environment(\.linkInfoService) private var linkInfoService
    @Environment(\.imageSuggestionService) private var imageSuggestions

    var body: some View {
        Form {
            Section {
                Toggle("Fetch webpage previews and video details automatically", isOn: $fetchesLinkDetails)
            } header: {
                Text("Links")
            } footer: {
                Text("After you save a webpage or a YouTube or Vimeo link, BenchBook reads the page for its preview image, title and description, or the video's poster, channel and length. This is the only time BenchBook goes online on its own. When it's off, use Refresh on a link to fetch its details.")
                    .foregroundStyle(.secondary)
            }

            if let imageSuggestions, imageSuggestions.availability().isOffered {
                let reason = imageSuggestions.availability().reason
                Section {
                    Toggle("Suggest titles and notes for new images", isOn: $suggestsImageDetails)
                        .disabled(reason != nil)
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text(reason ?? "Describes each new image on this Mac and fills in a title or note you haven't written. Images never leave your Mac. Suggestions can be wrong, so check details such as the variant or serial. In an image's details, Suggest Title and Note works whether this is on or off.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Image Viewer") {
                Picker("Open images at", selection: $opensImagesAtActualSize) {
                    Text("Fit to Window").tag(false)
                    Text("Actual Size").tag(true)
                }
                Toggle("Show note boxes when an image opens", isOn: $showsNoteBoxes)
            }

            Section("Projects") {
                Picker("Status for new projects", selection: $newProjectStatus) {
                    ForEach(ProjectStatus.allCases) { status in
                        Label(status.displayName, systemImage: status.systemImage).tag(status)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: fetchesLinkDetails) { _, isOn in
            // Catch up on links saved while it was off.
            if isOn { linkInfoService?.fetchMissing() }
        }
    }
}

private struct LibrarySettings: View {
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.modelContext) private var modelContext

    @State private var usage: LibraryUsage?
    @State private var status: String?

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Library") {
                    Text(libraryFolderPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([assetLibrary.rootURL])
                    }
                }
            }

            Section("Space Used") {
                if let usage {
                    sizeRow("Saved files", usage.originals)
                    sizeRow("Thumbnails", usage.thumbnails)
                    sizeRow("Posters and previews", usage.posters)
                    sizeRow("Total", usage.total)
                        .fontWeight(.semibold)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                LabeledContent {
                    Button("Clean Up Now", action: cleanUp)
                } label: {
                    Text("Remove unused files")
                    Text("Deletes saved files and previews that nothing uses any more, such as leftovers from an interrupted import. BenchBook also does this at launch.")
                }
                LabeledContent {
                    Button("Clear Thumbnails", action: clearThumbnails)
                } label: {
                    Text("Clear thumbnails")
                    Text("Deletes the gallery's thumbnails. Each is made again from its file when it's next shown.")
                }
            } header: {
                Text("Maintenance")
            } footer: {
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    /// The folder holding the store and the file library, without a trailing slash.
    private var libraryFolderPath: String {
        let path = assetLibrary.rootURL.deletingLastPathComponent().path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func sizeRow(_ title: LocalizedStringKey, _ bytes: Int64) -> some View {
        LabeledContent(title) {
            Text(bytes, format: .byteCount(style: .file))
                .monospacedDigit()
        }
    }

    private func measure() async {
        let library = assetLibrary
        usage = await Task.detached(priority: .userInitiated) { LibraryUsage.measure(library) }.value
    }

    private func cleanUp() {
        do {
            let removed = try ReferenceService(context: modelContext, library: assetLibrary).reconcileLibrary()
            status = removed == 0
                ? String(localized: "Nothing to clean up.")
                : String(AttributedString(localized: "Removed ^[\(removed) unused item](inflect: true).").inflected().characters)
        } catch {
            status = error.localizedDescription
        }
        Task { await measure() }
    }

    private func clearThumbnails() {
        thumbnailStore?.clearThumbnails()
        status = String(localized: "Thumbnails cleared.")
        Task { await measure() }
    }
}

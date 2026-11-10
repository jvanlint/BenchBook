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
            Tab("Backup", systemImage: "externaldrive.badge.timemachine") {
                BackupSettings()
                    .frame(height: 520)
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

/// Back up the library to one file, and restore one.
private struct BackupSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.libraryLocation) private var location
    @AppStorage(AppSettings.lastBackupKey) private var lastBackup: Double = 0

    @State private var progress = BackupProgress()
    @State private var isChecking = false
    @State private var status: String?
    @State private var restoreCandidate: BackupManifest?
    @State private var previousLibraries: [URL] = []
    @State private var libraryToTrash: URL?
    @State private var errorMessage: String?

    private var isBusy: Bool { progress.fraction != nil || isChecking }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Back Up Library…", action: backUp)
                        .disabled(isBusy || location == nil)
                } label: {
                    Text("Back up your library")
                    Text("Saves every project, reference, note, paint and original file into one file. Keep it on another drive or in cloud storage.")
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction) {
                        Text("Backing up…")
                    }
                }
            } header: {
                Text("Back Up")
            } footer: {
                Text(status ?? lastBackupText)
                    .foregroundStyle(.secondary)
            }

            Section("Restore") {
                LabeledContent {
                    Button("Restore from Backup…", action: chooseBackup)
                        .disabled(isBusy || location == nil)
                } label: {
                    Text("Restore a backup")
                    Text("Replaces this library with the backup. BenchBook checks the backup first, then quits and reopens to finish. The library you have now is kept.")
                }
                if isChecking {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking the backup…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !previousLibraries.isEmpty {
                Section {
                    ForEach(previousLibraries, id: \.self) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Move to Trash…") { libraryToTrash = url }
                        }
                    }
                } header: {
                    Text("Kept from Before a Restore")
                } footer: {
                    Text("Each is the whole library as it was before a restore. Keep it until you're sure the restore has everything.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: listPreviousLibraries)
        .confirmationDialog(
            restoreTitle,
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { cancelRestore() } }),
            presenting: restoreCandidate
        ) { manifest in
            Button("Restore and Reopen") { confirmRestore(manifest) }
            Button("Cancel", role: .cancel) { cancelRestore() }
        } message: { manifest in
            Text(restoreMessage(for: manifest))
        }
        .confirmationDialog(
            "Move “\(libraryToTrash?.lastPathComponent ?? "")” to the Trash?",
            isPresented: Binding(get: { libraryToTrash != nil }, set: { if !$0 { libraryToTrash = nil } }),
            presenting: libraryToTrash
        ) { url in
            Button("Move to Trash", role: .destructive) { trash(url) }
        } message: { _ in
            Text("It's no longer needed once you're sure the restored library has everything.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var lastBackupText: String {
        guard let date = AppSettings.lastBackup() else { return String(localized: "Not backed up yet.") }
        _ = lastBackup // Redraw when it changes.
        return String(localized: "Last backed up \(date.formatted(date: .long, time: .shortened)).")
    }

    private var currentCounts: BackupManifest.Counts {
        BackupManifest.Counts(
            projects: (try? modelContext.fetchCount(FetchDescriptor<Project>())) ?? 0,
            references: (try? modelContext.fetchCount(FetchDescriptor<Reference>())) ?? 0,
            paints: (try? modelContext.fetchCount(FetchDescriptor<Paint>())) ?? 0
        )
    }

    // MARK: Back up

    private func backUp() {
        guard let location else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.benchBookBackup]
        panel.nameFieldStringValue = "BenchBook Backup \(Date.now.formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let counts = currentCounts
        let version = CurrentSchema.versionIdentifier
        let schemaVersion = "\(version.major).\(version.minor).\(version.patch)"
        let appVersion = Bundle.main.shortVersion
        let progress = progress
        progress.fraction = 0
        status = nil
        Task {
            do {
                let manifest = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackup.backUp(
                        location, to: destination, appVersion: appVersion, schemaVersion: schemaVersion, counts: counts
                    ) { fraction in
                        Task { @MainActor in progress.update(fraction) }
                    }
                }.value
                lastBackup = manifest.createdAt.timeIntervalSince1970
                status = String(localized: "Backed up \(Self.summary(manifest)) to “\(destination.lastPathComponent)”.")
            } catch {
                errorMessage = error.localizedDescription
            }
            progress.fraction = nil
        }
    }

    /// e.g. "12 projects, 340 references and 1.2 GB of files".
    private static func summary(_ manifest: BackupManifest) -> String {
        let projects = AttributedString(localized: "^[\(manifest.counts.projects) project](inflect: true)").inflected()
        let references = AttributedString(localized: "^[\(manifest.counts.references) reference](inflect: true)").inflected()
        let size = manifest.totalSize.formatted(.byteCount(style: .file))
        return String(localized: "\(String(projects.characters)), \(String(references.characters)) and \(size) of files")
    }

    // MARK: Restore

    private func chooseBackup() {
        guard let location else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.benchBookBackup]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let archive = panel.url else { return }

        isChecking = true
        status = nil
        Task {
            do {
                restoreCandidate = try await LibraryRestore.prepare(archive, for: location)
            } catch {
                errorMessage = error.localizedDescription
            }
            isChecking = false
        }
    }

    private var restoreTitle: String {
        guard let date = restoreCandidate?.createdAt else { return "" }
        return String(localized: "Restore the Backup from \(date.formatted(date: .long, time: .shortened))?")
    }

    private func restoreMessage(for manifest: BackupManifest) -> String {
        let now = currentCounts
        let current = String(AttributedString(localized: "^[\(now.projects) project](inflect: true) and ^[\(now.references) reference](inflect: true)").inflected().characters)
        return String(localized: "It has \(Self.summary(manifest)). It replaces your library now, with \(current); BenchBook keeps that in a folder beside it and lists it here. BenchBook will quit and reopen to finish.")
    }

    private func confirmRestore(_ manifest: BackupManifest) {
        guard let location else { return }
        restoreCandidate = nil
        do {
            try LibraryRestore.schedule(manifest, for: location)
        } catch {
            LibraryRestore.discard(for: location)
            errorMessage = error.localizedDescription
            return
        }
        LibraryRestore.relaunch { message in errorMessage = message }
    }

    private func cancelRestore() {
        if let location, restoreCandidate != nil { LibraryRestore.discard(for: location) }
        restoreCandidate = nil
    }

    // MARK: Earlier libraries

    private func listPreviousLibraries() {
        previousLibraries = location.map { LibraryRestore.previousLibraries(for: $0) } ?? []
    }

    private func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        listPreviousLibraries()
    }
}

/// How far a backup has got; nil when none is running.
@Observable
private final class BackupProgress {
    var fraction: Double?

    func update(_ value: Double) {
        if fraction != nil { fraction = value }
    }
}

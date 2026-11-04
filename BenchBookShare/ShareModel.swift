import AppKit
import Foundation
import Observation

/// Reads the shared items, then hands them to BenchBook through the App Group inbox.
@Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        case ready
        /// BenchBook has no Projects yet, or hasn't been opened since installing.
        case noProjects
        case nothingToAdd
        case sending
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var items: [CapturedItem] = []
    private(set) var skipped: [String] = []
    private(set) var projects: [ProjectSummary] = []
    var selectedProjectID: UUID?
    var tagsText = ""
    var note = ""

    private let extensionItems: [NSExtensionItem]
    private let finish: (Bool) -> Void
    private let inbox = AppGroup.inboxURL.map(CaptureInboxStore.init)
    private let directory = AppGroup.defaults.map(ProjectDirectory.init)
    private var stagingFolder: URL?

    init(extensionItems: [NSExtensionItem], finish: @escaping (Bool) -> Void) {
        self.extensionItems = extensionItems
        self.finish = finish
    }

    var canSend: Bool {
        state == .ready && selectedProjectID != nil && !items.isEmpty
    }

    func load() async {
        projects = directory?.load() ?? []
        guard !projects.isEmpty else {
            state = .noProjects
            return
        }
        let active = directory?.activeProjectID
        selectedProjectID = projects.contains { $0.id == active } ? active : projects.first?.id

        guard let inbox, let folder = try? inbox.makeStagingFolder() else {
            state = .failed(String(localized: "BenchBook's shared folder isn't available. Open BenchBook once, then try again."))
            return
        }
        stagingFolder = folder

        let reader = ItemProviderReader(fileDirectory: folder, copiesFileURLs: true)
        for item in extensionItems {
            var providers = item.attachments ?? []
            var title = item.attributedTitle?.string.trimmedSingleLine
            // Some apps put the page title in the content text, others the selected text.
            if let content = item.attributedContentText?.string,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if title == nil, let short = content.trimmedSingleLine {
                    title = short
                } else if content.trimmedSingleLine != title {
                    providers.append(NSItemProvider(object: content as NSString))
                }
            }
            let result = await reader.read(providers, title: title)
            items += result.items
            skipped += result.skipped
        }
        state = items.isEmpty ? .nothingToAdd : .ready
    }

    func send() {
        guard canSend, let inbox, let folder = stagingFolder, let projectID = selectedProjectID else { return }
        state = .sending

        let envelopeItems: [CaptureEnvelope.Item] = items.map { item in
            switch item {
            case .file(let url, let originalFilename, let resourceURL):
                .file(name: url.lastPathComponent, originalFilename: originalFilename, resourceURL: resourceURL)
            case .link(let url, let title):
                .link(url: url, title: title)
            case .text(let text, let sourceURL, let title):
                .text(text, sourceURL: sourceURL, title: title)
            }
        }
        let envelope = CaptureEnvelope(
            id: UUID(),
            createdAt: .now,
            projectID: projectID,
            tags: TagNames.parse(tagsText),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
            items: envelopeItems
        )
        do {
            try inbox.commit(envelope, stagingFolder: folder)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        stagingFolder = nil
        directory?.activeProjectID = projectID
        launchBenchBookInBackground()
        finish(true)
    }

    func cancel() {
        if let stagingFolder {
            try? FileManager.default.removeItem(at: stagingFolder)
        }
        finish(false)
    }

    /// Opens BenchBook without bringing it forward, so it imports straight away.
    private func launchBenchBookInBackground() {
        // .../BenchBook.app/Contents/PlugIns/BenchBookShare.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

private extension String {
    /// Nil for blank or multi-line text, which isn't a usable title.
    var trimmedSingleLine: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline), value.count <= 300 else { return nil }
        return value
    }
}

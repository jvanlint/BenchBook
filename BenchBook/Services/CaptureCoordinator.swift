import AppKit
import Foundation
import Observation
import SwiftData

/// A message about a capture that needs the user's attention.
struct CaptureReport: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Runs captures from the window (drops, paste, file panel) and imports
/// envelopes the Share extension leaves in the App Group inbox.
@Observable
final class CaptureCoordinator {
    /// Set when a capture had duplicates or failures; cleared by the alert.
    var report: CaptureReport?
    /// Increments after each import, so views can react (e.g. select References).
    private(set) var importCount = 0
    /// Fetches details for newly saved video links.
    @ObservationIgnored var videoInfo: VideoInfoService?

    private let context: ModelContext
    private let library: AssetLibrary
    private let inbox: CaptureInboxStore?
    private var inboxWatcher: DispatchSourceFileSystemObject?
    private var isProcessingInbox = false
    private var needsAnotherInboxPass = false

    init(context: ModelContext, library: AssetLibrary, inbox: CaptureInboxStore?) {
        self.context = context
        self.library = library
        self.inbox = inbox
    }

    private var importer: ReferenceImporter {
        ReferenceImporter(context: context, library: library)
    }

    // MARK: - Window captures

    /// Imports dragged or pasted items into `project`.
    func capture(_ providers: [NSItemProvider], into project: Project) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "BenchBook-Capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let reader = ItemProviderReader(fileDirectory: folder, copiesFileURLs: false)
            let result = await reader.read(providers)
            let outcomes = await importer.importItems(result.items, into: project)
            finish(outcomes, skipped: result.skipped)
        }
    }

    /// Imports files chosen in the open panel into `project`.
    func capture(fileURLs: [URL], into project: Project) {
        let items = fileURLs.map { CapturedItem.file(url: $0, originalFilename: $0.lastPathComponent, resourceURL: nil) }
        Task {
            let outcomes = await importer.importItems(items, into: project)
            finish(outcomes, skipped: [])
        }
    }

    // MARK: - Share extension inbox

    /// Starts importing waiting envelopes and watching for new ones.
    func startInbox() {
        guard let inbox, inboxWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: inbox.inboxURL, withIntermediateDirectories: true)
        inbox.removeStaleStagingFolders()

        let descriptor = open(inbox.inboxURL.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processInbox() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            inboxWatcher = source
        }
        processInbox()
    }

    /// Imports every complete envelope. Safe to call repeatedly.
    func processInbox() {
        guard inbox != nil else { return }
        guard !isProcessingInbox else {
            needsAnotherInboxPass = true
            return
        }
        isProcessingInbox = true
        Task {
            repeat {
                needsAnotherInboxPass = false
                await importPendingEnvelopes()
            } while needsAnotherInboxPass
            isProcessingInbox = false
        }
    }

    private func importPendingEnvelopes() async {
        guard let inbox else { return }
        var outcomes: [CaptureOutcome] = []

        for folder in inbox.pendingFolders() {
            guard let envelope = try? inbox.readEnvelope(in: folder),
                  envelope.version <= CaptureEnvelope.currentVersion
            else {
                // Not readable yet, or from a newer version; leave it for later.
                continue
            }
            let items = envelope.capturedItems(in: folder)
            let projectID = envelope.projectID
            guard let project = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).first else {
                outcomes += items.compactMap { $0 }.map { .failed(item: $0, error: CaptureError.projectNotFound) }
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            for item in items {
                if let item {
                    outcomes += await importer.importItems([item], into: project, tags: envelope.tags, note: envelope.note)
                }
            }
            // Every item is now a durable Reference, a duplicate or a reported failure.
            try? FileManager.default.removeItem(at: folder)
        }
        if !outcomes.isEmpty {
            finish(outcomes, skipped: [])
        }
    }

    // MARK: - Reporting

    private func finish(_ outcomes: [CaptureOutcome], skipped: [String]) {
        importCount += 1
        videoInfo?.fetch(outcomes.compactMap { outcome in
            if case .added(let reference) = outcome { reference } else { nil }
        })

        var duplicates: [String] = []
        var failures: [String] = skipped.map { String(localized: "“\($0)” isn't a type BenchBook can save.") }
        for outcome in outcomes {
            switch outcome {
            case .added: break
            case .duplicate(let existing, _): duplicates.append(existing.displayTitle)
            case .failed(_, let error): failures.append(error.localizedDescription)
            }
        }

        if !failures.isEmpty {
            report = CaptureReport(
                title: failures.count == 1
                    ? String(localized: "An Item Couldn't Be Added")
                    : String(localized: "\(failures.count) Items Couldn't Be Added"),
                message: (failures + duplicates.map { String(localized: "“\($0)” is already saved to this project.") })
                    .joined(separator: "\n")
            )
        } else if !duplicates.isEmpty {
            report = CaptureReport(
                title: String(localized: "Already Saved to This Project"),
                message: duplicates.map { "“\($0)”" }.joined(separator: "\n")
            )
        }
    }
}

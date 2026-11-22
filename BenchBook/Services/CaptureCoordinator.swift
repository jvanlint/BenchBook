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
/// envelopes the Share and Safari extensions leave in the App Group inbox.
/// Safari waits for a result, which is written to the App Group.
@Observable
final class CaptureCoordinator {
    /// Set when a capture had duplicates or failures; cleared by the alert.
    var report: CaptureReport?
    /// Increments after each import, so views can react (e.g. select References).
    private(set) var importCount = 0
    /// Fetches details for newly saved video links.
    @ObservationIgnored var linkInfo: LinkInfoService?
    @ObservationIgnored var imageSuggestions: ImageSuggestionService?

    private let context: ModelContext
    private let library: AssetLibrary
    private let inbox: CaptureInboxStore?
    private let results: CaptureResultStore?
    private var inboxWatcher: DispatchSourceFileSystemObject?
    private var isProcessingInbox = false
    private var needsAnotherInboxPass = false

    init(context: ModelContext, library: AssetLibrary, inbox: CaptureInboxStore?, results: CaptureResultStore? = nil) {
        self.context = context
        self.library = library
        self.inbox = inbox
        self.results = results
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
        results?.removeStale()

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
        var importedAny = false

        for folder in inbox.pendingFolders() {
            guard let envelope = try? inbox.readEnvelope(in: folder),
                  envelope.version <= CaptureEnvelope.currentVersion
            else {
                // Not readable yet, or from a newer version; leave it for later.
                continue
            }
            let envelopeOutcomes = await importEnvelope(envelope, in: folder)
            // Every item is now a durable Reference, a duplicate or a reported failure.
            try? FileManager.default.removeItem(at: folder)
            importedAny = true

            if envelope.source == .safari {
                // Safari shows the result itself, so only failures also need an alert here.
                outcomes += envelopeOutcomes.filter {
                    if case .duplicate = $0 { false } else { true }
                }
            } else {
                outcomes += envelopeOutcomes
            }
        }
        if importedAny {
            finish(outcomes, skipped: [])
        }
    }

    /// Imports or amends one envelope and, for Safari, writes its result.
    private func importEnvelope(_ envelope: CaptureEnvelope, in folder: URL) async -> [CaptureOutcome] {
        let projectID = envelope.projectID
        let project = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).first

        if let referenceIDs = envelope.amends {
            writeResult(amend(referenceIDs, in: project, tags: envelope.tags, note: envelope.note), for: envelope, project: project)
            return []
        }

        let items = envelope.capturedItems(in: folder)
        guard let project else {
            let outcomes: [CaptureOutcome] = items.compactMap { $0 }.map { .failed(item: $0, error: CaptureError.projectNotFound) }
            writeResult(.failure(CaptureError.projectNotFound), for: envelope, project: nil)
            return outcomes
        }
        var outcomes: [CaptureOutcome] = []
        for item in items {
            if let item {
                outcomes += await importer.importItems([item], into: project, tags: envelope.tags, note: envelope.note,
                                                       pageURL: envelope.pageURL)
            }
        }
        writeResult(.success(outcomes), for: envelope, project: project)
        return outcomes
    }

    /// Change… in Safari: moves just-saved References to `project`, then adds
    /// the tags and note to those now in it. A Reference whose file the
    /// project already has stays where it was, as a duplicate.
    private func amend(_ referenceIDs: [UUID], in project: Project?, tags: [String], note: String?) -> Result<[CaptureOutcome], Error> {
        guard let project else { return .failure(CaptureError.projectNotFound) }
        do {
            let references = try context.fetch(FetchDescriptor<Reference>(predicate: #Predicate { referenceIDs.contains($0.id) }))
            guard !references.isEmpty else { return .failure(CaptureError.referenceNotFound) }
            let transfer = try ReferenceTransfer(context: context, library: library).transfer(references, to: project, mode: .move)
            let changed = references.filter { $0.project?.id == project.id }
            let service = ReferenceService(context: context, library: library)
            for reference in changed {
                try service.setTags(reference.tags.map(\.name) + tags, on: reference)
                if let note = note?.trimmedOrNil {
                    reference.note = [reference.note?.trimmedOrNil, note].compactMap { $0 }.joined(separator: "\n\n")
                }
                reference.updatedAt = .now
            }
            context.touchEditedProjects()
            try context.save()
            importCount += 1
            let duplicates: [CaptureOutcome] = transfer.duplicates.map { reference in
                reference.sourcePageURL.map { .duplicate(existing: reference, item: .link(url: $0, title: nil)) }
                    ?? .duplicate(existing: reference, item: .text(reference.displayTitle, sourceURL: nil, title: nil))
            }
            return .success(changed.map(CaptureOutcome.added) + duplicates)
        } catch {
            context.rollback()
            return .failure(error)
        }
    }

    private func writeResult(_ outcome: Result<[CaptureOutcome], Error>, for envelope: CaptureEnvelope, project: Project?) {
        guard envelope.source == .safari, let results else { return }
        var result = CaptureResult(envelopeID: envelope.id, status: .failed, projectName: project?.name)
        switch outcome {
        case .failure(let error):
            result.message = error.localizedDescription
        case .success(let outcomes):
            for outcome in outcomes {
                switch outcome {
                case .added(let reference):
                    result.status = .saved
                    result.referenceIDs.append(reference.id)
                case .duplicate:
                    if result.status != .saved { result.status = .duplicate }
                case .failed(_, let error):
                    if result.referenceIDs.isEmpty, result.status == .failed {
                        result.message = error.localizedDescription
                    }
                }
            }
            if outcomes.isEmpty { result.message = CaptureError.nothingToSave.localizedDescription }
        }
        try? results.write(result)
    }

    // MARK: - Reporting

    private func finish(_ outcomes: [CaptureOutcome], skipped: [String]) {
        importCount += 1
        let added = outcomes.compactMap { outcome in
            if case .added(let reference) = outcome { reference } else { nil }
        }
        linkInfo?.fetch(added)
        imageSuggestions?.suggestForNewImages(added)

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

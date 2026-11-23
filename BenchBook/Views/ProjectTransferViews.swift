import AppKit
import SwiftData
import SwiftUI

/// Project › Export Project… and File › Import Project…, for ContentView.
struct ProjectTransferModifier: ViewModifier {
    /// The project to export; the sheet shows while it's set.
    @Binding var exportRequest: Project?
    @Binding var isImporting: Bool
    /// Called before a project is replaced, so its windows can close.
    var willReplace: (Project) -> Void
    var didImport: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary

    @State private var pendingFile: ProjectFile?
    @State private var existingName: String?
    @State private var isWorking = false
    @State private var notice: (title: String, message: String, file: URL?)?

    func body(content: Content) -> some View {
        content
            .sheet(item: $exportRequest) { project in
                ProjectExportSheet(project: project) { includePersonal in
                    export(project, includePersonal: includePersonal)
                }
            }
            // On its own view: ContentView has a file importer of its own,
            // and two on one view get in each other's way.
            .background {
                Color.clear
                    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.benchBookProject]) { result in
                        if case .success(let url) = result { open(url) }
                    }
            }
            .confirmationDialog(
                "“\(existingName ?? "")” Is Already in Your Library",
                isPresented: Binding(get: { existingName != nil }, set: { if !$0 { existingName = nil } })
            ) {
                Button("Replace") { finishImport(.replace) }
                Button("Keep Both") { finishImport(.keepBoth) }
                Button("Cancel", role: .cancel) { cancelImport() }
            } message: {
                Text("Replace it with the version in the file, or keep both? Replacing loses any changes made to it since the file was exported.")
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                presenting: notice
            ) { notice in
                if let file = notice.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .overlay {
                if isWorking {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
    }

    // MARK: Export

    private func export(_ project: Project, includePersonal: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.benchBookProject]
        panel.nameFieldStringValue = ProjectExporter.suggestedFilename(for: project)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let version = CurrentSchema.versionIdentifier
        let package: ProjectExporter.Package
        do {
            try modelContext.save()
            package = try ProjectExporter(library: assetLibrary).package(
                project, includePersonalDetails: includePersonal, appVersion: Bundle.main.shortVersion,
                schemaVersion: "\(version.major).\(version.minor).\(version.patch)"
            )
        } catch {
            notice = (String(localized: "Couldn't Export Project"), error.localizedDescription, nil)
            return
        }
        let name = project.name
        isWorking = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ProjectExporter.write(package, to: destination)
                }.value
                notice = (
                    String(localized: "Project Exported"),
                    String(localized: "“\(name)” is saved in “\(destination.lastPathComponent)”. BenchBook on a Mac or a Windows PC can import it with File › Import Project…."),
                    destination
                )
            } catch {
                notice = (String(localized: "Couldn't Export Project"), error.localizedDescription, nil)
            }
            isWorking = false
        }
    }

    // MARK: Import

    private func open(_ url: URL) {
        let staging = FileManager.default.temporaryDirectory.appending(path: "BenchBook Import", directoryHint: .isDirectory)
        isWorking = true
        Task {
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try ProjectFile.open(url, staging: staging)
                }.value
                isWorking = false
                pendingFile = file
                if let existing = try importer.existingProject(for: file) {
                    existingName = existing.name
                } else {
                    finishImport(.add)
                }
            } catch {
                isWorking = false
                notice = (String(localized: "Couldn't Import Project"), error.localizedDescription, nil)
            }
        }
    }

    private var importer: ProjectImporter { ProjectImporter(context: modelContext, library: assetLibrary) }

    private func finishImport(_ mode: ProjectImporter.Mode) {
        guard let file = pendingFile else { return }
        defer { cancelImport() }
        do {
            if mode == .replace, let existing = try importer.existingProject(for: file) {
                willReplace(existing)
            }
            let summary = try importer.importProject(file, mode: mode)
            let id = summary.projectID
            if let project = try modelContext.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first {
                ImageViewerRequests.shared.didAdd(project.references.map(\.id) + project.buildPhotos.map(\.id))
            }
            didImport(id)
            notice = (String(localized: "Project Imported"), Self.message(for: summary, counts: file.manifest.counts), nil)
        } catch {
            notice = (String(localized: "Couldn't Import Project"), error.localizedDescription, nil)
        }
    }

    private func cancelImport() {
        pendingFile?.discard()
        pendingFile = nil
        existingName = nil
    }

    static func message(for summary: ProjectImporter.Summary, counts: ProjectFileManifest.Counts) -> String {
        var lines = [
            String(localized: "“\(summary.projectName)” has ^[\(counts.references) reference](inflect: true), ^[\(counts.buildPhotos) build photo](inflect: true) and ^[\(counts.aftermarketItems) aftermarket part](inflect: true)."),
        ]
        if summary.paintsAdded + summary.paintsMatched > 0 {
            lines.append(String(localized: "Paints: ^[\(summary.paintsAdded) added](inflect: true) to your catalogue, \(summary.paintsMatched) already there."))
        }
        if summary.tagsAdded > 0 {
            lines.append(String(localized: "^[\(summary.tagsAdded) new tag](inflect: true)."))
        }
        if summary.kitsAdded + summary.kitsMatched > 0 {
            lines.append(String(localized: "Kits: ^[\(summary.kitsAdded) added](inflect: true) to your catalogue, \(summary.kitsMatched) already there."))
        }
        if !summary.kitsInOtherProjects.isEmpty {
            let names = summary.kitsInOtherProjects.formatted(.list(type: .and))
            lines.append(String(localized: "\(names) stayed in the project already building them."))
        }
        return lines.joined(separator: "\n")
    }
}

/// Chooses whether a project export carries personal details.
private struct ProjectExportSheet: View {
    let project: Project
    let onExport: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includesPersonalDetails = false

    var body: some View {
        Form {
            Section {
                Toggle("Include kit prices and paint ownership", isOn: $includesPersonalDetails)
            } footer: {
                Text("The project is saved with its references, notes, tags, build photos, paint list, aftermarket parts, kits and files, in one file BenchBook on a Mac or a Windows PC can import. Leave prices and ownership out when sharing it with someone else.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .navigationTitle("Export “\(project.name)”")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export…") {
                    let choice = includesPersonalDetails
                    dismiss()
                    // After the sheet closes, so the Save panel isn't behind it.
                    Task { @MainActor in onExport(choice) }
                }
            }
        }
    }
}

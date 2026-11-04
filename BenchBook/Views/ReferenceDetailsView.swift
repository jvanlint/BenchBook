import SwiftData
import SwiftUI

/// Shows a Reference's details and lets the user edit its title, tags and note.
struct ReferenceDetailsView: View {
    let reference: Reference

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var tagsText: String
    @State private var note: String
    @State private var errorMessage: String?

    init(reference: Reference) {
        self.reference = reference
        _title = State(initialValue: reference.title ?? "")
        _tagsText = State(initialValue: reference.tags.map(\.name).joined(separator: ", "))
        _note = State(initialValue: reference.note ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, prompt: Text(reference.displayTitle))
                TextField("Tags", text: $tagsText, prompt: Text("Separate tags with commas"))
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Reference Details")
                    .font(.headline)
            }

            if let text = reference.text {
                Section("Text") {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if reference.kind == .videoLink, let source = reference.sourcePageURL, !reference.videoMoments.isEmpty {
                Section("Moments") {
                    ForEach(reference.sortedVideoMoments) { moment in
                        Link(
                            moment.title ?? VideoLink.format(seconds: moment.offsetSeconds),
                            destination: VideoLink.playbackURL(for: source, at: moment.offsetSeconds)
                        )
                    }
                }
            }

            Section("Information") {
                LabeledContent("Type", value: reference.kind?.displayName ?? reference.kindRaw)
                LabeledContent("Added", value: reference.capturedAt.formatted(date: .abbreviated, time: .shortened))
                if let source = reference.sourcePageURL {
                    LabeledContent("Source") {
                        Link(source.host() ?? source.absoluteString, destination: source)
                    }
                }
                if let resource = reference.originalResourceURL {
                    LabeledContent("Original File") {
                        Link(resource.lastPathComponent, destination: resource)
                    }
                }
                if let asset = reference.asset {
                    if let filename = asset.originalFilename {
                        LabeledContent("File Name", value: filename)
                    }
                    LabeledContent("Size", value: asset.byteCount.formatted(.byteCount(style: .file)))
                    if let width = asset.pixelWidth, let height = asset.pixelHeight {
                        LabeledContent("Dimensions", value: "\(width) × \(height)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .alert(
            "Couldn't Save Reference",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try ReferenceService(context: modelContext, library: assetLibrary)
                .updateDetails(reference, title: title, note: note, tagsText: tagsText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

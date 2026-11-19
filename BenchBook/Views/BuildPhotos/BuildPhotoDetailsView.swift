import SwiftData
import SwiftUI

/// Edits a build photo's notes, date taken, stage and tags.
struct BuildPhotoDetailsView: View {
    let photo: BuildPhoto

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.dismiss) private var dismiss

    @State private var notes: String
    @State private var takenAt: Date
    @State private var stage: BuildPhotoStage
    @State private var tagsText: String
    @State private var thumbnail: NSImage?
    @State private var errorMessage: String?

    init(photo: BuildPhoto) {
        self.photo = photo
        _notes = State(initialValue: photo.notes ?? "")
        _takenAt = State(initialValue: photo.takenAt)
        _stage = State(initialValue: photo.stage)
        _tagsText = State(initialValue: photo.tags.map(\.name).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build Photo Details")
                .font(.headline)

            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .frame(width: 140, height: 105)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                Form {
                    Picker("Stage", selection: $stage) {
                        ForEach(BuildPhotoStage.allCases) { stage in
                            Text(stage.displayName).tag(stage)
                        }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Taken", selection: $takenAt)
                }
                .formStyle(.columns)
            }

            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Notes (optional). The first line shows under the photo.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Notes")

            TextField("Tags", text: $tagsText, prompt: Text("Tags, separated with commas"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: photo.asset?.id) {
            if let thumbnailStore, let asset = photo.asset {
                thumbnail = await thumbnailStore.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            }
        }
        .alert(
            "Couldn't Save Build Photo",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try BuildPhotoService(context: modelContext, library: assetLibrary)
                .update(photo, notes: notes, takenAt: takenAt, stage: stage, tagsText: tagsText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

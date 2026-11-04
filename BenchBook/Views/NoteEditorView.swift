import SwiftData
import SwiftUI

/// Writes a new note into a Project's References, or edits one.
struct NoteEditorView: View {
    enum Request: Identifiable {
        case new(Project)
        case edit(Reference)

        var id: String {
            switch self {
            case .new(let project): "new-\(project.id)"
            case .edit(let reference): reference.id.uuidString
            }
        }
    }

    let request: Request

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text: String
    @State private var tagsText: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case title, text }

    init(request: Request) {
        self.request = request
        if case .edit(let reference) = request {
            _title = State(initialValue: reference.title ?? "")
            _text = State(initialValue: reference.text ?? "")
            _tagsText = State(initialValue: reference.tags.map(\.name).joined(separator: ", "))
        } else {
            _title = State(initialValue: "")
            _text = State(initialValue: "")
            _tagsText = State(initialValue: "")
        }
    }

    private var isNew: Bool {
        if case .new = request { true } else { false }
    }

    private var isEmpty: Bool {
        title.trimmedOrNil == nil && text.trimmedOrNil == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Note" : "Edit Note")
                .font(.headline)
            TextField("Title", text: $title, prompt: Text("Title (optional)"))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .title)
            TextEditor(text: $text)
                .font(.body)
                .focused($focusedField, equals: .text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write your note…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Note")
            TextField("Tags", text: $tagsText, prompt: Text("Tags, separated with commas"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Note" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .onAppear { focusedField = isNew ? .text : nil }
        .alert(
            "Couldn't Save Note",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let service = ReferenceService(context: modelContext, library: assetLibrary)
        do {
            switch request {
            case .new(let project):
                try service.createNote(in: project, title: title, text: text, tagsText: tagsText)
            case .edit(let reference):
                try service.updateNote(reference, title: title, text: text, tagsText: tagsText)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

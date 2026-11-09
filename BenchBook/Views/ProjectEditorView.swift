import SwiftData
import SwiftUI

enum ProjectEditorRequest: Identifiable {
    case new
    case edit(Project)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let project): project.id.uuidString
        }
    }

    var project: Project? {
        if case .edit(let project) = self { project } else { nil }
    }
}

/// Sheet for creating or editing a Project. Changes are kept in a draft and
/// only saved when the user confirms.
struct ProjectEditorView: View {
    let request: ProjectEditorRequest
    let onSaved: (Project) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProjectDraft
    @State private var saveErrorMessage: String?
    @FocusState private var nameFieldFocused: Bool

    init(request: ProjectEditorRequest, onSaved: @escaping (Project) -> Void) {
        self.request = request
        self.onSaved = onSaved
        if let project = request.project {
            _draft = State(initialValue: ProjectDraft(project: project))
        } else {
            var draft = ProjectDraft()
            draft.status = AppSettings.newProjectStatus()
            _draft = State(initialValue: draft)
        }
    }

    private var isNew: Bool { request.project == nil }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                    .focused($nameFieldFocused)
                TextField("Manufacturer", text: $draft.manufacturer, prompt: Text("e.g. Tamiya"))
                TextField("Subject", text: $draft.subject, prompt: Text("e.g. F-16CJ Block 50"))
                TextField("Scale", text: $draft.scale, prompt: Text("e.g. 1:48"))
                TextField("Kit Number", text: $draft.kitNumber, prompt: Text("Optional"))
                TextField("Markings Scheme", text: $draft.markingsScheme, prompt: Text("Optional"))
                Picker("Status", selection: $draft.status) {
                    ForEach(ProjectStatus.allCases) { status in
                        Label(status.displayName, systemImage: status.systemImage).tag(status)
                    }
                }
            } header: {
                Text(isNew ? "New Project" : "Edit Project")
                    .font(.headline)
            } footer: {
                if !draft.hasValidName {
                    Text("Enter a name to save the project.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notes") {
                TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(4...10)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 480)
        .defaultFocus($nameFieldFocused, true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Save", action: save)
                    .disabled(!draft.hasValidName)
            }
        }
        .alert(
            "Couldn't Save Project",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private func save() {
        let service = ProjectService(context: modelContext)
        do {
            let project: Project
            if let existing = request.project {
                try service.update(existing, from: draft)
                project = existing
            } else {
                project = try service.createProject(from: draft)
            }
            onSaved(project)
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

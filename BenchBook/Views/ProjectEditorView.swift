import SwiftData
import SwiftUI

enum ProjectEditorRequest: Identifiable {
    case new
    /// A new project using this kit, named after it.
    case newFromKit(Kit)
    case edit(Project)

    var id: String {
        switch self {
        case .new: "new"
        case .newFromKit(let kit): "new-\(kit.id.uuidString)"
        case .edit(let project): project.id.uuidString
        }
    }

    var project: Project? {
        if case .edit(let project) = self { project } else { nil }
    }
}

/// Sheet for creating or editing a Project. Changes are kept in a draft and
/// only saved when the user confirms. A new project can choose its kits
/// here; an existing one changes them in its Kits section.
struct ProjectEditorView: View {
    let request: ProjectEditorRequest
    let onSaved: (Project) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProjectDraft
    @State private var saveErrorMessage: String?
    /// Kits for a new project, in the order chosen.
    @State private var kits: [Kit] = []
    @State private var isPickingKits = false
    @State private var isCreatingKit = false
    @FocusState private var nameFieldFocused: Bool

    init(request: ProjectEditorRequest, onSaved: @escaping (Project) -> Void) {
        self.request = request
        self.onSaved = onSaved
        if let project = request.project {
            _draft = State(initialValue: ProjectDraft(project: project))
        } else {
            var draft = ProjectDraft()
            draft.status = AppSettings.newProjectStatus()
            if case .newFromKit(let kit) = request {
                draft.name = kit.name
                _kits = State(initialValue: [kit])
            }
            _draft = State(initialValue: draft)
        }
    }

    private var isNew: Bool { request.project == nil }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                    .focused($nameFieldFocused)
                TextField("Subject", text: $draft.subject, prompt: Text("e.g. F-16CJ Block 50"))
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

            if isNew {
                kitsSection
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
        .sheet(isPresented: $isPickingKits) {
            KitPickerView(projectName: nil, excluding: Set(kits.map(\.id))) { chosen in
                kits += chosen
            }
        }
        .sheet(isPresented: $isCreatingKit) {
            NavigationStack {
                KitEditorView(request: .new) { kit in kits.append(kit) }
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
                project = try service.createProject(from: draft, kits: kits)
            }
            onSaved(project)
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private var kitsSection: some View {
        Section {
            ForEach(kits) { kit in
                HStack(spacing: 8) {
                    KitThumbnail(kit: kit)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kit.name)
                        Text([kit.brand, kit.scale ?? "", kit.number ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        kits.removeAll { $0.id == kit.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Don't use this kit in the new project")
                    .accessibilityLabel("Remove \(kit.displayName)")
                }
            }
            HStack {
                Button("Add from Kits…") { isPickingKits = true }
                Button("New Kit…") { isCreatingKit = true }
                    .help("Add a kit to your catalogue and to this project")
            }
        } header: {
            Text("Kits")
        } footer: {
            Text("New kits go into your Kits catalogue straight away, even if you cancel.")
                .foregroundStyle(.secondary)
        }
    }
}

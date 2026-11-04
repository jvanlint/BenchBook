import SwiftUI

/// Actions the focused window offers to the menu bar.
struct ProjectActions {
    var newProject: () -> Void
    /// Nil when no Project is selected.
    var editProject: (() -> Void)?
    /// Nil when no Project is selected.
    var addFiles: (() -> Void)?
}

/// Writes a new note in the Project shown in the focused window.
struct NoteAction {
    var newNote: () -> Void
}

extension FocusedValues {
    @Entry var projectActions: ProjectActions?
    @Entry var workspaceSection: Binding<WorkspaceSection>?
    /// Nil when no Project is shown or a note is already open.
    @Entry var noteAction: NoteAction?
}

struct BenchBookCommands: Commands {
    @FocusedValue(\.projectActions) private var projectActions
    @FocusedValue(\.workspaceSection) private var workspaceSection
    @FocusedValue(\.noteAction) private var noteAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                projectActions?.newProject()
            }
            .keyboardShortcut("n")
            .disabled(projectActions == nil)

            Button("Add Files to Project…") {
                projectActions?.addFiles?()
            }
            .keyboardShortcut("o")
            .disabled(projectActions?.addFiles == nil)

            Button("New Note…") {
                noteAction?.newNote()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(noteAction == nil)
        }

        CommandMenu("Project") {
            Button("Edit Project…") {
                projectActions?.editProject?()
            }
            .keyboardShortcut("i")
            .disabled(projectActions?.editProject == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(WorkspaceSection.allCases) { section in
                Button(section.title) {
                    workspaceSection?.wrappedValue = section
                }
                .keyboardShortcut(section.keyEquivalent)
                .disabled(workspaceSection == nil)
            }
            Divider()
        }
    }
}

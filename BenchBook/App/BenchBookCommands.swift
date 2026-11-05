import SwiftUI

/// Actions the focused window offers to the menu bar.
struct ProjectActions {
    var newProject: () -> Void
    /// Nil when no Project is selected.
    var editProject: (() -> Void)?
    /// Nil when no Project is selected.
    var addFiles: (() -> Void)?
}

/// Puts the cursor in the focused window's search field.
struct SearchAction {
    var focus: () -> Void
}

/// Edits the tags of the References selected in the focused window.
struct TagAction {
    var editTags: () -> Void
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
    @Entry var searchAction: SearchAction?
    /// Nil when no References are selected.
    @Entry var tagAction: TagAction?
}

struct BenchBookCommands: Commands {
    @FocusedValue(\.projectActions) private var projectActions
    @FocusedValue(\.workspaceSection) private var workspaceSection
    @FocusedValue(\.noteAction) private var noteAction
    @FocusedValue(\.searchAction) private var searchAction
    @FocusedValue(\.tagAction) private var tagAction

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

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") {
                searchAction?.focus()
            }
            .keyboardShortcut("f")
            .disabled(searchAction == nil)
        }

        CommandMenu("Project") {
            Button("Edit Project…") {
                projectActions?.editProject?()
            }
            .keyboardShortcut("i")
            .disabled(projectActions?.editProject == nil)

            Button("Edit Tags…") {
                tagAction?.editTags()
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(tagAction == nil)
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

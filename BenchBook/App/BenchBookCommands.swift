import SwiftUI

/// Actions the focused window offers to the menu bar.
struct ProjectActions {
    var newProject: () -> Void
    /// Nil when no Project is selected.
    var editProject: (() -> Void)?
    /// Nil when no Project is selected.
    var addFiles: (() -> Void)?
}

extension FocusedValues {
    @Entry var projectActions: ProjectActions?
    @Entry var workspaceSection: Binding<WorkspaceSection>?
}

struct BenchBookCommands: Commands {
    @FocusedValue(\.projectActions) private var projectActions
    @FocusedValue(\.workspaceSection) private var workspaceSection

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

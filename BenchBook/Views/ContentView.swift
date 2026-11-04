import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Project.name, comparator: .localizedStandard)])
    private var projects: [Project]

    @State private var selectedProjectID: UUID?
    @State private var editorRequest: ProjectEditorRequest?

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                projects: projects,
                selection: $selectedProjectID,
                onAdd: { editorRequest = .new },
                onEdit: { editorRequest = .edit($0) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 440)
        .sheet(item: $editorRequest) { request in
            ProjectEditorView(request: request) { project in
                selectedProjectID = project.id
            }
        }
        .focusedSceneValue(\.projectActions, editorRequest == nil ? projectActions : nil)
    }

    @ViewBuilder
    private var detail: some View {
        if let project = selectedProject {
            ProjectWorkspaceView(project: project) {
                editorRequest = .edit(project)
            }
            // A fresh workspace per Project, so each one opens on References.
            .id(project.id)
        } else if projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "hammer")
            } description: {
                Text("Create a project for each build to keep its references, paint and aftermarket parts together.")
            } actions: {
                Button("New Project") { editorRequest = .new }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "No Project Selected",
                systemImage: "sidebar.left",
                description: Text("Select a project in the sidebar.")
            )
        }
    }

    private var projectActions: ProjectActions {
        ProjectActions(
            newProject: { editorRequest = .new },
            editProject: selectedProject.map { project in { editorRequest = .edit(project) } }
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Project.self, inMemory: true)
}

import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Project.name, comparator: .localizedStandard)])
    private var projects: [Project]

    @Environment(\.captureCoordinator) private var captureCoordinator
    @Environment(\.projectDirectory) private var projectDirectory

    @State private var selection: SidebarItem?
    @State private var editorRequest: ProjectEditorRequest?
    @State private var isAddingFiles = false

    private var selectedProjectID: UUID? { selection?.projectID }

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                projects: projects,
                selection: $selection,
                onAdd: { editorRequest = .new },
                onEdit: { editorRequest = .edit($0) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(item: $editorRequest) { request in
            ProjectEditorView(request: request) { project in
                selection = .project(project.id)
            }
        }
        .fileImporter(
            isPresented: $isAddingFiles,
            allowedContentTypes: ItemProviderReader.fileTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, let project = selectedProject {
                captureCoordinator?.capture(fileURLs: urls, into: project)
            }
        }
        .alert(
            captureCoordinator?.report?.title ?? "",
            isPresented: Binding(
                get: { captureCoordinator?.report != nil },
                set: { if !$0 { captureCoordinator?.report = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(captureCoordinator?.report?.message ?? "")
        }
        .focusedSceneValue(\.projectActions, editorRequest == nil ? projectActions : nil)
        .onAppear(perform: restoreSelection)
        .onChange(of: selection?.projectID) { _, id in
            if let id { projectDirectory?.activeProjectID = id }
        }
        .onChange(of: projects.map { Self.summary($0) }, initial: true) { _, summaries in
            projectDirectory?.publish(summaries)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection == .paints {
            PaintCatalogueView()
        } else if let project = selectedProject {
            ProjectWorkspaceView(
                project: project,
                onEdit: { editorRequest = .edit(project) },
                onAddFiles: { isAddingFiles = true }
            )
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
            editProject: selectedProject.map { project in { editorRequest = .edit(project) } },
            addFiles: selectedProject.map { _ in { isAddingFiles = true } }
        )
    }

    /// Reopens the project last used in the app or share sheet.
    private func restoreSelection() {
        guard selection == nil, let id = projectDirectory?.activeProjectID,
              projects.contains(where: { $0.id == id })
        else { return }
        selection = .project(id)
    }

    private static func summary(_ project: Project) -> ProjectSummary {
        ProjectSummary(id: project.id, name: project.name, detail: project.summary)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Project.self, inMemory: true)
}

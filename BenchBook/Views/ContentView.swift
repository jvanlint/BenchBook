import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: [SortDescriptor(\Project.name, comparator: .localizedStandard)])
    private var projects: [Project]
    @Query(sort: [SortDescriptor(\Tag.name, comparator: .localizedStandard)])
    private var tags: [Tag]

    @Environment(\.captureCoordinator) private var captureCoordinator
    @Environment(\.projectDirectory) private var projectDirectory
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.restoreNotice) private var restoreNotice

    @State private var selection: SidebarItem?
    @State private var editorRequest: ProjectEditorRequest?
    @State private var isAddingFiles = false
    @State private var searchText = ""
    @State private var searchTokens: [SearchTagToken] = []
    @FocusState private var isSearchFocused: Bool
    @State private var revealReferenceID: UUID?
    @State private var revealPaintID: UUID?
    @State private var revealAftermarketID: UUID?
    @State private var projectPendingDeletion: Project?
    @State private var deletionError: String?
    @State private var transferNotice: ReferenceTransferNotice?
    @State private var transferError: String?

    private var searchQuery: SearchQuery {
        SearchQuery(text: searchText, tags: Set(searchTokens.map(\.normalizedName)))
    }

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
                onEdit: { editorRequest = .edit($0) },
                onDelete: { projectPendingDeletion = $0 }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
                .overlay(alignment: .bottom) {
                    if let notice = transferNotice {
                        ReferenceTransferBanner(notice: notice) {
                            transferNotice = nil
                            selection = .project(notice.projectID)
                        } onClose: {
                            transferNotice = nil
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(6))
                            if transferNotice?.id == notice.id { transferNotice = nil }
                        }
                    }
                }
                .animation(.default, value: transferNotice)
        }
        .environment(\.transferReferences, ReferenceTransferAction(perform: transfer))
        .frame(minWidth: 760, minHeight: 480)
        .searchable(text: $searchText, tokens: $searchTokens, placement: .toolbar, prompt: "Search All Projects") { token in
            Label(token.name, systemImage: "tag")
        }
        .searchSuggestions {
            ForEach(tagSuggestions) { token in
                Label(token.name, systemImage: "tag")
                    .searchCompletion(token)
            }
        }
        .searchFocused($isSearchFocused)
        .onChange(of: searchTokens) { old, new in
            // Choosing a tag suggestion replaces the word typed to find it.
            guard new.count > old.count, let added = new.last, let typed = lastWord,
                  SearchField.fold(added.name).contains(SearchField.fold(typed))
            else { return }
            searchText = String(searchText.dropLast(typed.count)).trimmingCharacters(in: .whitespaces)
        }
        .focusedSceneValue(\.searchAction, SearchAction { isSearchFocused = true })
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
        .confirmationDialog(
            "Delete “\(projectPendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { projectPendingDeletion != nil }, set: { if !$0 { projectPendingDeletion = nil } }),
            presenting: projectPendingDeletion
        ) { project in
            Button("Delete Project", role: .destructive) { delete(project) }
        } message: { project in
            Text(deletionMessage(for: project))
        }
        .alert(
            "Couldn't Delete Project",
            isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .alert(
            "Couldn't Move or Copy",
            isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferError ?? "")
        }
        .alert(
            restoreNotice?.outcome.map { Self.restoreTitle($0) } ?? "",
            isPresented: Binding(get: { restoreNotice?.outcome != nil }, set: { if !$0 { restoreNotice?.dismiss() } }),
            presenting: restoreNotice?.outcome
        ) { outcome in
            if case .restored(_, let previous) = outcome {
                Button("Show Earlier Library") { NSWorkspace.shared.activateFileViewerSelecting([previous]) }
            }
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(Self.restoreMessage(outcome))
        }
        .focusedSceneValue(\.projectActions, editorRequest == nil ? projectActions : nil)
        .onAppear(perform: restoreSelection)
        // Choosing something in the sidebar leaves search.
        .onChange(of: selection) { endSearch() }
        .onChange(of: selection?.projectID) { _, id in
            if let id { projectDirectory?.activeProjectID = id }
        }
        .onChange(of: projects.map { Self.summary($0) }, initial: true) { _, summaries in
            projectDirectory?.publish(summaries)
        }
    }

    /// The tag chosen in the sidebar, if any.
    private var selectedTag: Tag? {
        guard case .tag(let id) = selection else { return nil }
        return tags.first { $0.id == id }
    }

    @ViewBuilder
    private var detail: some View {
        if case .tag = selection {
            if let tag = selectedTag {
                // Typing in the search field narrows the tag's references.
                searchResults(
                    SearchQuery(text: searchText, tags: Set(searchTokens.map(\.normalizedName) + [tag.normalizedName])),
                    title: tag.name
                )
            } else {
                ContentUnavailableView("Tag Not Found", systemImage: "tag.slash",
                                       description: Text("This tag may have been deleted or merged."))
            }
        } else if !searchQuery.isEmpty {
            searchResults(searchQuery, title: String(localized: "Search"))
        } else if selection == .tags {
            TagManagerView { tag in selection = .tag(tag.id) }
        } else if selection == .paints {
            PaintCatalogueView(revealID: $revealPaintID)
        } else if selection == .shoppingList {
            ShoppingListView { paintID in
                selection = .paints
                revealPaintID = paintID
            }
        } else if let project = selectedProject {
            ProjectWorkspaceView(
                project: project,
                onEdit: { editorRequest = .edit(project) },
                onAddFiles: { isAddingFiles = true },
                revealReferenceID: $revealReferenceID,
                revealAftermarketID: $revealAftermarketID
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

    private func searchResults(_ query: SearchQuery, title: String) -> some View {
        SearchResultsView(
            query: query,
            title: title,
            onShowProject: { project in
                endSearch()
                selection = .project(project.id)
            },
            onShowReference: { reference in
                guard let projectID = reference.project?.id else { return }
                endSearch()
                selection = .project(projectID)
                revealReferenceID = reference.id
            },
            onShowPaint: { paint in
                endSearch()
                selection = .paints
                revealPaintID = paint.id
            },
            onShowAftermarketItem: { item in
                guard let projectID = item.project?.id else { return }
                endSearch()
                selection = .project(projectID)
                revealAftermarketID = item.id
            }
        )
    }

    /// The word being typed, used to suggest tags.
    private var lastWord: String? {
        guard let last = searchText.last, !last.isWhitespace else { return nil }
        return searchText.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    /// Tags matching the word being typed, not already chosen.
    private var tagSuggestions: [SearchTagToken] {
        guard let word = lastWord.map(SearchField.fold) else { return [] }
        let chosen = Set(searchTokens.map(\.normalizedName))
        return tags
            .filter { !chosen.contains($0.normalizedName) && SearchField.fold($0.name).contains(word) }
            .prefix(8)
            .map { SearchTagToken(normalizedName: $0.normalizedName, name: $0.name) }
    }

    private func endSearch() {
        searchText = ""
        searchTokens = []
    }

    private var projectActions: ProjectActions {
        ProjectActions(
            newProject: { editorRequest = .new },
            editProject: selectedProject.map { project in { editorRequest = .edit(project) } },
            addFiles: selectedProject.map { _ in { isAddingFiles = true } },
            deleteProject: selectedProject.map { project in { projectPendingDeletion = project } }
        )
    }

    private func deletionMessage(for project: Project) -> String {
        let contents = project.deletionSummary
        let kept = String(localized: "Paints in your catalogue and your tags are kept. This can't be undone.")
        return contents.isEmpty
            ? String(localized: "The project is empty. \(kept)")
            : String(localized: "Its \(contents) will be deleted. \(kept)")
    }

    private func transfer(_ references: [Reference], to project: Project, mode: ReferenceTransfer.Mode) {
        do {
            let result = try ReferenceTransfer(context: modelContext, library: assetLibrary)
                .transfer(references, to: project, mode: mode)
            guard !result.transferred.isEmpty || !result.duplicates.isEmpty else { return }
            let notice = ReferenceTransferNotice(result: result, mode: mode, project: project)
            transferNotice = notice
            AccessibilityNotification.Announcement(notice.message).post()
        } catch {
            transferError = error.localizedDescription
        }
    }

    private static func restoreTitle(_ outcome: LibraryRestore.Outcome) -> String {
        switch outcome {
        case .restored: String(localized: "Library Restored")
        case .failed: String(localized: "Restore Didn't Finish")
        }
    }

    private static func restoreMessage(_ outcome: LibraryRestore.Outcome) -> String {
        switch outcome {
        case .restored(let date, let previous):
            String(localized: "Your library is back as it was on \(date.formatted(date: .long, time: .shortened)). The library you had before is kept in “\(previous.lastPathComponent)”, also listed in Settings › Backup.")
        case .failed(let message):
            message
        }
    }

    private func delete(_ project: Project) {
        // Leave the project and close its image windows before its records go.
        if selectedProjectID == project.id { selection = nil }
        ImageViewerRequests.shared.willDelete(project.references.map(\.id))
        for reference in project.references where reference.kind == .image {
            dismissWindow(id: ImageViewerWindow.id, value: reference.id)
        }
        do {
            try ProjectService(context: modelContext).delete(project, library: assetLibrary)
        } catch {
            deletionError = error.localizedDescription
        }
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

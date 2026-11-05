import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar can show in the main area.
enum SidebarItem: Hashable {
    case paints
    /// The page for managing every tag.
    case tags
    /// Everything with one tag, across all projects.
    case tag(UUID)
    case project(UUID)

    var projectID: UUID? {
        if case .project(let id) = self { id } else { nil }
    }
}

struct ProjectSidebar: View {
    let projects: [Project]
    @Binding var selection: SidebarItem?
    let onAdd: () -> Void
    let onEdit: (Project) -> Void

    @Query private var tags: [Tag]
    @AppStorage("sidebar.showsAllTags") private var showsAllTags = false
    @State private var nameSheet: TagNameSheet.Mode?
    @State private var tagPendingDeletion: Tag?

    /// Most used first. Collapsed, only the top ten are listed.
    private static let collapsedTagCount = 10

    private var sortedTags: [Tag] { tags.sorted(by: Tag.byUsage) }

    private var visibleTags: [Tag] {
        showsAllTags ? sortedTags : Array(sortedTags.prefix(Self.collapsedTagCount))
    }

    var body: some View {
        List(selection: $selection) {
            Section("Projects") {
                ForEach(projects) { project in
                    ProjectRow(project: project)
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button("Edit Project…") { onEdit(project) }
                        }
                }
            }
            Section("Library") {
                Label("Paints", systemImage: "paintpalette")
                    .tag(SidebarItem.paints)
                Label("Tags", systemImage: "tag")
                    .tag(SidebarItem.tags)
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(visibleTags) { tag in
                        TagRow(tag: tag)
                            .tag(SidebarItem.tag(tag.id))
                            .contextMenu {
                                Button("Show References") { selection = .tag(tag.id) }
                                Button("Rename…") { nameSheet = .rename(tag) }
                                TagColorPicker(tags: [tag])
                                Divider()
                                Button("Manage Tags…") { selection = .tags }
                                Button("Delete Tag…", role: .destructive) { tagPendingDeletion = tag }
                            }
                    }
                    if tags.count > Self.collapsedTagCount {
                        Button(showsAllTags ? "Show Less" : "Show More (\(tags.count - Self.collapsedTagCount))") {
                            showsAllTags.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(showsAllTags ? "Show only the ten most used tags" : "Show every tag")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Project", systemImage: "plus", action: onAdd)
                    .help("Add Project")
            }
        }
        .sheet(item: $nameSheet) { mode in
            NavigationStack { TagNameSheet(mode: mode) }
        }
        .confirmationDialog(
            "Delete “\(tagPendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { tagPendingDeletion != nil }, set: { if !$0 { tagPendingDeletion = nil } }),
            presenting: tagPendingDeletion
        ) { tag in
            Button("Delete", role: .destructive) { delete(tag) }
        } message: { tag in
            Text(tag.usageCount == 0
                 ? "No references use it."
                 : "It will be removed from \(tag.usageCount) references. The references themselves aren't deleted.")
        }
    }

    @Environment(\.modelContext) private var modelContext

    private func delete(_ tag: Tag) {
        if selection == .tag(tag.id) { selection = .tags }
        try? TagService(context: modelContext).delete([tag])
    }
}

/// A tag in the sidebar. Drag it onto references to tag them, or drag
/// references onto it.
private struct TagRow: View {
    let tag: Tag

    @Environment(\.modelContext) private var modelContext
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tag.displayColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(tag.name)
                .lineLimit(1)
            Spacer()
            Text(tag.usageCount, format: .number)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(tag.usageCount) references")
        }
        .contentShape(Rectangle())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tag.displayColor, lineWidth: 2)
                    .padding(-4)
            }
        }
        .draggable(TagDragItem(tagID: tag.id)) {
            TagChips.chip(tag.name, color: tag.displayColor)
        }
        .dropDestination(for: ReferencesDragItem.self) { items, _ in
            tagReferences(items.flatMap(\.referenceIDs))
        } isTargeted: { isDropTargeted = $0 }
        .help("Drag onto references to tag them, or drag references here")
    }

    private func tagReferences(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            let references = try modelContext.fetch(FetchDescriptor<Reference>(predicate: #Predicate { ids.contains($0.id) }))
            try TagService(context: modelContext).add(tag, to: references)
            return true
        } catch {
            Logger.capture.error("Tagging dropped references failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    @Environment(\.captureCoordinator) private var captureCoordinator
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .lineLimit(1)
            if !project.summary.isEmpty {
                Text(project.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
            }
        }
        .accessibilityElement(children: .combine)
        // Dropping onto a row adds to that project without selecting it.
        .onDrop(of: CaptureDrop.types, isTargeted: $isDropTargeted) { providers in
            captureCoordinator?.capture(CaptureDrop.providers(fallback: providers), into: project)
            return true
        }
    }
}

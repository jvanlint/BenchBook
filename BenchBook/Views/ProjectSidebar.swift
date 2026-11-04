import SwiftUI

struct ProjectSidebar: View {
    let projects: [Project]
    @Binding var selection: UUID?
    let onAdd: () -> Void
    let onEdit: (Project) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Projects") {
                ForEach(projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Edit Project…") { onEdit(project) }
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
    }
}

private struct ProjectRow: View {
    let project: Project

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
        .accessibilityElement(children: .combine)
    }
}

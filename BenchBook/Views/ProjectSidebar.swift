import SwiftUI
import UniformTypeIdentifiers

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
            captureCoordinator?.capture(providers, into: project)
            return true
        }
    }
}

/// What the window accepts from drags and paste.
enum CaptureDrop {
    static let types: [UTType] = [.fileURL, .image, .pdf, .url, .plainText]
}

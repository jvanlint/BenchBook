import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case references
    case paint
    case aftermarket

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .references: "References"
        case .paint: "Paint"
        case .aftermarket: "Aftermarket"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .references: "1"
        case .paint: "2"
        case .aftermarket: "3"
        }
    }
}

struct ProjectWorkspaceView: View {
    let project: Project
    let onEdit: () -> Void

    @State private var section: WorkspaceSection = .references

    var body: some View {
        WorkspaceSectionPlaceholder(section: section)
            .navigationTitle(project.name)
            .navigationSubtitle(project.summary)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(WorkspaceSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Switch between References, Paint and Aftermarket")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit Project", systemImage: "pencil", action: onEdit)
                        .help("Edit Project")
                }
            }
            .focusedSceneValue(\.workspaceSection, $section)
    }
}

/// Empty states for each section until adding items is built.
private struct WorkspaceSectionPlaceholder: View {
    let section: WorkspaceSection

    var body: some View {
        switch section {
        case .references:
            ContentUnavailableView(
                "No References",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Images, PDFs, webpages and video links you save for this project will appear here.")
            )
        case .paint:
            ContentUnavailableView(
                "No Paint",
                systemImage: "paintpalette",
                description: Text("The colours this build needs, and the paints you choose for them, will appear here.")
            )
        case .aftermarket:
            ContentUnavailableView(
                "No Aftermarket Parts",
                systemImage: "shippingbox",
                description: Text("Decals, resin, photo-etch and other parts you're using or considering for this build will appear here.")
            )
        }
    }
}

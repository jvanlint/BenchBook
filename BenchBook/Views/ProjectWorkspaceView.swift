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
    let onAddFiles: () -> Void

    @Environment(\.captureCoordinator) private var captureCoordinator
    @Environment(\.appearsActive) private var appearsActive
    @State private var pasteOwner = UUID()
    @State private var section: WorkspaceSection = .references
    /// Kept here so it survives switching sections; resets per Project.
    @State private var referenceFilter = ReferenceFilter()
    @State private var isDropTargeted = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: CaptureDrop.types, isTargeted: $isDropTargeted) { providers in
                capture(providers)
                return true
            }
            // ⌘V pastes into the project shown in the front window.
            .onChange(of: appearsActive, initial: true) { _, active in
                if active {
                    PasteRouter.shared.register(owner: pasteOwner) { providers in capture(providers) }
                }
            }
            .onDisappear { PasteRouter.shared.unregister(owner: pasteOwner) }
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add Files", systemImage: "plus.rectangle.on.rectangle", action: addFiles)
                        .help("Add images, PDFs or Markdown files to this project")
                    Button("Edit Project", systemImage: "pencil", action: onEdit)
                        .help("Edit Project")
                }
            }
            .focusedSceneValue(\.workspaceSection, $section)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .references:
            ReferencesView(project: project, filter: $referenceFilter, onAddFiles: addFiles)
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

    private func addFiles() {
        referenceFilter = ReferenceFilter()
        onAddFiles()
    }

    /// Everything dropped or pasted becomes a Reference, so show all References.
    private func capture(_ providers: [NSItemProvider]) {
        section = .references
        referenceFilter = ReferenceFilter()
        captureCoordinator?.capture(providers, into: project)
    }
}

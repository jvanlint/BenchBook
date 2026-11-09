import SwiftUI

/// Moves or copies References to another Project, then reports the result
/// in the window. Provided by ContentView.
struct ReferenceTransferAction {
    let perform: ([Reference], Project, ReferenceTransfer.Mode) -> Void

    func callAsFunction(_ references: [Reference], to project: Project, mode: ReferenceTransfer.Mode) {
        perform(references, project, mode)
    }
}

extension EnvironmentValues {
    @Entry var transferReferences: ReferenceTransferAction?
}

/// What a move or copy did, shown briefly at the bottom of the window.
struct ReferenceTransferNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let projectID: UUID
    let projectName: String

    init(result: ReferenceTransfer.Result, mode: ReferenceTransfer.Mode, project: Project) {
        projectID = project.id
        projectName = project.name
        let name = project.name
        let count = result.transferred.count
        var lines: [String] = []
        if count == 1, let reference = result.transferred.first {
            lines.append(mode == .move
                ? String(localized: "Moved “\(reference.displayTitle)” to \(name).")
                : String(localized: "Copied “\(reference.displayTitle)” to \(name)."))
        } else if count > 1 {
            lines.append(mode == .move
                ? String(localized: "Moved \(count) references to \(name).")
                : String(localized: "Copied \(count) references to \(name)."))
        }
        let duplicates = result.duplicates.count
        if duplicates == 1, let reference = result.duplicates.first {
            lines.append(String(localized: "\(name) already has “\(reference.displayTitle)”, so it was left as it is."))
        } else if duplicates > 1 {
            lines.append(String(localized: "\(name) already has \(duplicates) of these files, so they were left as they are."))
        }
        message = lines.joined(separator: " ")
    }
}

/// A short confirmation with a button to go to the target Project.
struct ReferenceTransferBanner: View {
    let notice: ReferenceTransferNotice
    let onShow: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(notice.message)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show \(notice.projectName)", action: onShow)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

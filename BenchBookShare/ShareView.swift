import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var tagsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to BenchBook")
                .font(.headline)
                .padding([.horizontal, .top], 20)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if model.state == .ready {
                    Text("Items are added when BenchBook is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { model.send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading, .sending:
            ProgressView()
        case .noProjects:
            ContentUnavailableView(
                "No Projects",
                systemImage: "hammer",
                description: Text("Open BenchBook and create a project, then share again.")
            )
        case .nothingToAdd:
            ContentUnavailableView(
                "Nothing to Add",
                systemImage: "exclamationmark.triangle",
                description: Text(unsupportedDescription)
            )
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't Send to BenchBook",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .ready:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                    Label(item.summary, systemImage: item.systemImage)
                        .lineLimit(2)
                }
                if !model.skipped.isEmpty {
                    Text(unsupportedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Project", selection: $model.selectedProjectID) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                TextField("Tags", text: $model.tagsText, prompt: Text("e.g. wheel well, cockpit"))
                    .focused($tagsFocused)
                TextField("Note", text: $model.note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .formStyle(.grouped)
        .defaultFocus($tagsFocused, true)
    }

    private var unsupportedDescription: String {
        let names = model.skipped.joined(separator: ", ")
        return names.isEmpty
            ? String(localized: "BenchBook can save images, PDFs, Markdown files, web links and text.")
            : String(localized: "Can't add: \(names). BenchBook can save images, PDFs, Markdown files, web links and text.")
    }
}

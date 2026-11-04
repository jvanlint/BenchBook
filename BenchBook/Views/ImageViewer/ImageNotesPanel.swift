import SwiftUI

/// The viewer's side panel: one numbered, editable row per box.
struct ImageNotesPanel: View {
    let notes: [ImageNote]
    @Binding var selection: UUID?
    /// Set to a new note's ID to move the cursor into its text.
    @Binding var noteToFocus: UUID?
    let service: ImageNoteService
    let onDelete: (ImageNote) -> Void

    @FocusState private var focusedNote: UUID?

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "rectangle.dashed")
                } description: {
                    Text("Choose Draw Box, then drag across a feature of the aircraft to mark it and add a note.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        row(note, number: index + 1)
                            .tag(note.id)
                            .contextMenu {
                                Button("Delete Note…", role: .destructive) { onDelete(note) }
                            }
                    }
                }
                .onDeleteCommand {
                    if let note = notes.first(where: { $0.id == selection }) { onDelete(note) }
                }
            }
        }
        .navigationTitle("Notes")
        .onChange(of: noteToFocus) { _, id in
            guard let id else { return }
            focusedNote = id
            noteToFocus = nil
        }
        .onChange(of: focusedNote) { old, new in
            if let new { selection = new }
            if old != nil { try? service.commit() }
        }
    }

    private func row(_ note: ImageNote, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 20, minHeight: 20)
                .background(selection == note.id ? Color.accentColor : Color.yellow, in: Circle())
                .foregroundStyle(selection == note.id ? .white : .black)
                .accessibilityLabel("Note \(number)")

            TextField(
                "Note \(number)",
                text: Binding(get: { note.text }, set: { service.setText($0, on: note) }),
                prompt: Text("Describe this feature"),
                axis: .vertical
            )
            .lineLimit(1...8)
            .textFieldStyle(.plain)
            .focused($focusedNote, equals: note.id)
            .onSubmit { try? service.commit() }
        }
        .padding(.vertical, 4)
    }
}

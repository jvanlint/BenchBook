import SwiftData
import SwiftUI

enum PaintEditorRequest: Identifiable {
    case new
    case edit(Paint)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let paint): paint.id.uuidString
        }
    }

    var paint: Paint? {
        if case .edit(let paint) = self { paint } else { nil }
    }
}

/// Sheet for adding or editing a catalogue paint.
struct PaintEditorView: View {
    let request: PaintEditorRequest
    var onSaved: (Paint) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allPaints: [Paint]

    @State private var draft: PaintDraft
    @State private var swatch: Color
    @State private var errorMessage: String?
    @FocusState private var brandFocused: Bool

    /// `standardCode` fills in a new paint's colour standard.
    init(request: PaintEditorRequest, standardCode: String = "", onSaved: @escaping (Paint) -> Void = { _ in }) {
        self.request = request
        self.onSaved = onSaved
        var draft = request.paint.map { PaintDraft(paint: $0) } ?? PaintDraft()
        if request.paint == nil { draft.standardCode = standardCode }
        _draft = State(initialValue: draft)
        _swatch = State(initialValue: SwatchColor.color(draft.swatchHex) ?? .gray)
    }

    private var isNew: Bool { request.paint == nil }

    /// Brands and ranges already in the catalogue, for typing suggestions.
    private var brands: [String] { Self.distinct(allPaints.map(\.brand)) }
    private var ranges: [String] {
        Self.distinct(allPaints.filter { $0.brand.caseInsensitiveCompare(draft.brand) == .orderedSame }.map(\.range))
    }

    var body: some View {
        Form {
            Section {
                TextField("Brand", text: $draft.brand, prompt: Text("Required, e.g. Tamiya"))
                    .focused($brandFocused)
                    .textInputSuggestions {
                        ForEach(brands.filter { $0.localizedCaseInsensitiveContains(draft.brand) && $0 != draft.brand }, id: \.self) {
                            Text($0).textInputCompletion($0)
                        }
                    }
                TextField("Range", text: $draft.range, prompt: Text("e.g. Acrylic XF"))
                    .textInputSuggestions {
                        ForEach(ranges.filter { $0.localizedCaseInsensitiveContains(draft.range) && $0 != draft.range }, id: \.self) {
                            Text($0).textInputCompletion($0)
                        }
                    }
                TextField("Code", text: $draft.code, prompt: Text("Required, e.g. XF-54"))
                TextField("Name", text: $draft.name, prompt: Text("e.g. Dark Sea Grey"))
                TextField("FS / RLM", text: $draft.standardCode, prompt: Text("e.g. FS 36270 or RLM 76"))
                    .help("The colour standard this paint matches. Separate several with a slash.")
            } header: {
                Text(isNew ? "New Paint" : "Edit Paint")
                    .font(.headline)
            } footer: {
                if draft.missingRequiredField {
                    Text("Enter a brand and a code to save the paint.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show a Swatch", isOn: Binding(
                    get: { draft.swatchHex != nil },
                    set: { draft.swatchHex = $0 ? SwatchColor.hex(from: swatch) : nil }
                ))
                if draft.swatchHex != nil {
                    ColorPicker("Swatch Colour", selection: $swatch, supportsOpacity: false)
                        .onChange(of: swatch) { _, color in draft.swatchHex = SwatchColor.hex(from: color) }
                }
                Toggle("I Own This Paint", isOn: $draft.isOwned)
            } footer: {
                Text("The swatch only helps you recognise the paint on screen; it isn't an accurate colour match.")
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                TextField("Notes", text: $draft.notes, prompt: Text("Optional, e.g. thin 1:1 with X-20A"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 480)
        .defaultFocus($brandFocused, true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save", action: save)
                    .disabled(draft.missingRequiredField)
            }
        }
        .alert(
            "Couldn't Save Paint",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let service = PaintService(context: modelContext)
        do {
            let paint: Paint
            if let existing = request.paint {
                try service.update(existing, from: draft)
                paint = existing
            } else {
                paint = try service.createPaint(from: draft)
            }
            onSaved(paint)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

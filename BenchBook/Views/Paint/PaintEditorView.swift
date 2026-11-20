import SwiftData
import SwiftUI

enum PaintEditorRequest: Identifiable {
    case new
    case newMix
    case edit(Paint)

    var id: String {
        switch self {
        case .new: "new"
        case .newMix: "new-mix"
        case .edit(let paint): paint.id.uuidString
        }
    }

    var paint: Paint? {
        if case .edit(let paint) = self { paint } else { nil }
    }
}

/// Sheet for adding or editing a catalogue paint, or a custom mix with a
/// recipe of other catalogue paints.
struct PaintEditorView: View {
    let request: PaintEditorRequest
    var onSaved: (Paint) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allPaints: [Paint]

    @State private var draft: PaintDraft
    @State private var swatch: Color
    @State private var errorMessage: String?
    @State private var isAddingToRecipe = false
    @FocusState private var brandFocused: Bool

    /// `standard` fills in a new paint's colour standard.
    init(request: PaintEditorRequest, standard: PaintStandard? = nil, onSaved: @escaping (Paint) -> Void = { _ in }) {
        self.request = request
        self.onSaved = onSaved
        var draft = request.paint.map { PaintDraft(paint: $0) } ?? PaintDraft()
        if case .newMix = request { draft.isMix = true }
        if request.paint == nil, let standard {
            draft.standardSystem = standard.system
            draft.standardCode = standard.code
        }
        _draft = State(initialValue: draft)
        _swatch = State(initialValue: SwatchColor.color(draft.swatchHex) ?? .gray)
    }

    private var isNew: Bool { request.paint == nil }

    private var title: LocalizedStringKey {
        switch (isNew, draft.isMix) {
        case (true, false): "New Paint"
        case (true, true): "New Mix"
        case (false, false): "Edit Paint"
        case (false, true): "Edit Mix"
        }
    }

    private var paintsByID: [UUID: Paint] {
        Dictionary(uniqueKeysWithValues: allPaints.map { ($0.id, $0) })
    }

    /// Brands and ranges already in the catalogue, for typing suggestions.
    private var brands: [String] { Self.distinct(allPaints.map(\.brand)) }
    private var ranges: [String] {
        Self.distinct(allPaints.filter { $0.brand.caseInsensitiveCompare(draft.brand) == .orderedSame }.map(\.range))
    }

    var body: some View {
        Form {
            Section {
                TextField("Brand", text: $draft.brand,
                          prompt: Text(draft.isMix ? "Required, e.g. Custom or your name" : "Required, e.g. Tamiya"))
                    .focused($brandFocused)
                    .textInputSuggestions {
                        ForEach(brands.filter { $0.localizedCaseInsensitiveContains(draft.brand) && $0 != draft.brand }, id: \.self) {
                            Text($0).textInputCompletion($0)
                        }
                    }
                if !draft.isMix {
                    TextField("Range", text: $draft.range, prompt: Text("e.g. Acrylic XF"))
                        .textInputSuggestions {
                            ForEach(ranges.filter { $0.localizedCaseInsensitiveContains(draft.range) && $0 != draft.range }, id: \.self) {
                                Text($0).textInputCompletion($0)
                            }
                        }
                }
                TextField("Code", text: $draft.code, prompt: Text(draft.isMix ? "Optional" : "Required, e.g. XF-54"))
                TextField("Name", text: $draft.name,
                          prompt: Text(draft.isMix ? "Required, e.g. Faded Sky Grey" : "e.g. Dark Sea Grey"))
                Picker("Type", selection: $draft.type) {
                    Text("Not Set").tag(PaintType?.none)
                    Divider()
                    ForEach(PaintType.allCases) { type in
                        Text(type.displayName).tag(Optional(type))
                            .help(type.hint)
                    }
                }
                .help(draft.type?.hint ?? String(localized: "What the paint is made with, so you use the right thinner"))
            } header: {
                Text(title)
                    .font(.headline)
            } footer: {
                if draft.missingRequiredField {
                    Text(draft.isMix ? "Enter a brand and a name to save the mix." : "Enter a brand and a code to save the paint.")
                        .foregroundStyle(.secondary)
                }
            }

            if draft.isMix {
                recipeSection
            }

            Section {
                Picker("Standard", selection: $draft.standardSystem) {
                    Text("None").tag(PaintStandardSystem?.none)
                    Divider()
                    ForEach(PaintStandardSystem.allCases) { system in
                        Text(system.displayName).tag(Optional(system))
                            .help(system.subjects)
                    }
                }
                .help(draft.standardSystem?.subjects ?? String(localized: "The colour standard you plan to use with this paint"))
                if let system = draft.standardSystem {
                    TextField("Standard Code",
                              text: $draft.standardCode, prompt: Text(system.codePrompt))
                    Picker("Match", selection: $draft.match) {
                        Text("Not Set").tag(PaintMatch?.none)
                        Divider()
                        ForEach(PaintMatch.allCases) { match in
                            Text(match.displayName).tag(Optional(match))
                        }
                    }
                    .help("How closely this paint matches the standard")
                }
            } header: {
                Text("Colour Standard")
            } footer: {
                if draft.standardSystem == nil {
                    Text("Most paints don't follow a standard. Choose one when you use this paint for a standard colour, such as FS 36270.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show a Swatch", isOn: Binding(
                    get: { draft.swatchHex != nil },
                    set: { draft.swatchHex = $0 ? SwatchColor.hex(from: swatch) : nil }
                ))
                if draft.swatchHex != nil {
                    LabeledContent {
                        HStack(spacing: 8) {
                            // Clears show as glass, as everywhere else.
                            PaintSwatch(hex: draft.swatchHex, isClear: PaintClarity.isClear(name: draft.name), size: 20)
                            ColorPicker("Swatch Colour", selection: $swatch, supportsOpacity: false)
                                .labelsHidden()
                        }
                    } label: {
                        Text("Swatch Colour")
                    }
                    .onChange(of: swatch) { _, color in draft.swatchHex = SwatchColor.hex(from: color) }
                }
                if !draft.isMix {
                    Toggle("I Own This Paint", isOn: $draft.isOwned)
                }
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
                    .disabled(draft.missingRequiredField || draft.hasBadParts)
            }
        }
        .sheet(isPresented: $isAddingToRecipe) {
            RecipePaintPicker(excluding: Set(draft.recipe.map(\.paintID) + [request.paint?.id].compactMap { $0 })) { paints in
                draft.recipe += paints.map { MixPartDraft(paintID: $0.id) }
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

    // MARK: Recipe

    private var recipeSection: some View {
        Section {
            ForEach($draft.recipe) { $line in
                if let paint = paintsByID[line.paintID] {
                    HStack(spacing: 8) {
                        PaintSwatch(hex: paint.swatchHex, isClear: paint.isClear)
                        Text(paint.displayName)
                            .lineLimit(1)
                        Spacer()
                        TextField("Parts", value: $line.parts, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .accessibilityLabel("Parts of \(paint.displayName)")
                        Text(line.parts == 1 ? "part" : "parts")
                            .foregroundStyle(.secondary)
                        Button {
                            draft.recipe.removeAll { $0.paintID == line.paintID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Take \(paint.displayName) out of the recipe")
                        .accessibilityLabel("Remove \(paint.displayName)")
                    }
                }
            }
            .onMove { draft.recipe.move(fromOffsets: $0, toOffset: $1) }
            Button("Add Paints…", systemImage: "plus") { isAddingToRecipe = true }
                .help("Choose catalogue paints for this mix")
        } header: {
            Text("Recipe")
        } footer: {
            Text(recipeFooter)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether the user can mix it with the paints they own.
    private var recipeFooter: String {
        let paints = draft.recipe.compactMap { paintsByID[$0.paintID] }
        if draft.hasBadParts { return String(localized: "Each paint needs a number of parts more than zero.") }
        if paints.isEmpty {
            return String(localized: "Add the paints you mix, with how many parts of each. Changes for one project go in that project's notes for the colour.")
        }
        let missing = paints.filter { !$0.isOwned }.map(\.displayName)
        if missing.isEmpty { return String(localized: "You own every paint in this recipe, so the mix counts as owned.") }
        return String(localized: "Not owned yet: \(missing.formatted(.list(type: .and))). Projects using this mix put them on the Shopping List.")
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

/// Sheet for choosing catalogue paints for a mix's recipe. Mixes aren't
/// listed, as a recipe is made of paints you can buy.
private struct RecipePaintPicker: View {
    /// Paints already in the recipe, and the mix itself.
    let excluding: Set<UUID>
    let onChoose: ([Paint]) -> Void

    @Query(filter: #Predicate<Paint> { !$0.isMix }, sort: [
        SortDescriptor(\Paint.brand, comparator: .localizedStandard),
        SortDescriptor(\Paint.code, comparator: .localizedStandard),
    ])
    private var paints: [Paint]

    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<UUID>()
    @State private var searchText = ""

    private var candidates: [Paint] {
        paints.filter { !excluding.contains($0.id) && $0.matches(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Paints to Recipe")
                .font(.headline)
                .padding(.top, 16)
            TextField("Search", text: $searchText, prompt: Text("Search brand, code, name or standard"))
                .textFieldStyle(.roundedBorder)
                .padding(12)
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label(paints.isEmpty ? "No Paints in Catalogue" : "No Matching Paints", systemImage: "paintpalette")
                } description: {
                    Text(paints.isEmpty
                         ? "Add the paints you mix to your catalogue first, from Paints in the sidebar."
                         : "No paint that isn't already in the recipe matches the search.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(candidates) { paint in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(paint.id) },
                        set: { on in if on { chosen.insert(paint.id) } else { chosen.remove(paint.id) } }
                    )) {
                        HStack(spacing: 8) {
                            PaintSwatch(hex: paint.swatchHex, isClear: paint.isClear)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(paint.displayName)
                                if !paint.secondaryLine.isEmpty {
                                    Text(paint.secondaryLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if paint.isOwned {
                                Text("Owned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Add \(chosen.count) Paints" : "Add Paint") {
                    onChoose(candidates.filter { chosen.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 440, height: 500)
    }
}

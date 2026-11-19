import SwiftData
import SwiftUI

/// Adds or edits a kit. Nothing is saved until Save.
struct KitEditorView: View {
    enum Request: Identifiable {
        case new
        case edit(Kit)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let kit): kit.id.uuidString
            }
        }
    }

    let request: Request
    /// A new kit is added to this project as well as the catalogue.
    var project: Project?
    /// Called with the kit once it's saved, e.g. to select it.
    var onSave: (Kit) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: KitDraft
    /// Set once a new kit is first saved, so retrying after an error
    /// doesn't add it twice.
    @State private var savedKit: Kit?
    @State private var pictureChange = PictureChange.unchanged
    @State private var preview: NSImage?
    @State private var isFetchingPicture = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Dropped and downloaded pictures wait here until Save.
    @State private var workFolder = FileManager.default.temporaryDirectory
        .appending(path: "BenchBook-Kit-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(request: Request, project: Project? = nil, onSave: @escaping (Kit) -> Void = { _ in }) {
        self.request = request
        self.project = project
        self.onSave = onSave
        switch request {
        case .new:
            _draft = State(initialValue: KitDraft())
        case .edit(let kit):
            _draft = State(initialValue: KitDraft(kit: kit))
            _savedKit = State(initialValue: kit)
        }
    }

    private var service: KitService { KitService(context: modelContext, library: assetLibrary) }

    private var isNew: Bool {
        if case .new = request { true } else { false }
    }

    /// Other entries for the same kit, for "You already have 2 of this kit".
    private var otherCopies: [Kit] {
        (try? service.copies(brand: draft.brand, number: draft.number.trimmedOrNil, scale: draft.scale.trimmedOrNil,
                             link: draft.parsedLink, excluding: savedKit)) ?? []
    }

    var body: some View {
        Form {
            Section {
                TextField("Brand", text: $draft.brand, prompt: Text("e.g. Italeri"))
                TextField("Name", text: $draft.name, prompt: Text("e.g. Super Cobra"))
                TextField("Scale", text: $draft.scale, prompt: Text("e.g. 1:72"))
                TextField("Number", text: $draft.number, prompt: Text("Optional"))
            } footer: {
                copiesFooter
            }

            Section {
                Toggle("Owned", isOn: $draft.isOwned)
                Picker("Status", selection: $draft.status) {
                    ForEach(KitStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                            .help(status.longName)
                    }
                }
                .disabled(!draft.isOwned)
                LabeledContent("Rating") {
                    StarRatingControl(stars: $draft.stars)
                }
            } footer: {
                if !draft.isOwned {
                    Text("Kits you don't own yet have no status.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Link", text: $draft.link, prompt: Text("Scalemates, a shop or the maker"))
                    .textContentType(.URL)
            } footer: {
                if !draft.hasValidLink {
                    Text("Enter a web address, such as scalemates.com/kits/…")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Price Paid", text: $draft.pricePaid, prompt: Text(KitPrice.display(Decimal(string: "18.50")!)))
                Toggle("For Sale", isOn: $draft.isForSale)
                TextField("Sale Price", text: $draft.salePrice, prompt: Text("Optional"))
                    .disabled(!draft.isForSale)
            } footer: {
                if !draft.hasValidPricePaid || !draft.hasValidSalePrice {
                    Text("Enter prices as numbers, such as 18.50.")
                        .foregroundStyle(.red)
                }
            }

            Section("Picture") {
                PictureWell(
                    change: $pictureChange,
                    preview: $preview,
                    isFetching: $isFetchingPicture,
                    hasStoredPicture: savedKit?.picture != nil,
                    pageURL: draft.parsedLink,
                    workFolder: workFolder,
                    accessibilityLabel: "Box art",
                    onLinkDropped: { url in
                        // A dropped link fills in Link if it's empty.
                        guard draft.link.trimmedOrNil == nil else { return false }
                        draft.link = url.absoluteString
                        return true
                    },
                    onError: { errorMessage = $0 }
                )
            }

            Section {
                TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle(isNew ? "New Kit" : "Edit Kit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!draft.isValid || isSaving || isFetchingPicture)
            }
        }
        .task {
            if let asset = savedKit?.picture {
                preview = await thumbnailStore?.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            }
        }
        .onDisappear {
            try? FileManager.default.removeItem(at: workFolder)
        }
        .alert(
            "Couldn't Save Kit",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var copiesFooter: some View {
        let count = otherCopies.count
        if count > 0 {
            Text(isNew
                 ? "You already have \(count) of this kit. This adds another."
                 : "You have \(count) more of this kit.")
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let kit: Kit
                if let savedKit {
                    try service.update(savedKit, from: draft)
                    kit = savedKit
                } else {
                    kit = try service.create(from: draft, in: project)
                    savedKit = kit
                }
                switch pictureChange {
                case .unchanged: break
                case .removed: try service.removePicture(from: kit)
                case .file(let url): try await service.setPicture(from: url, on: kit)
                }
                pictureChange = .unchanged
                onSave(kit)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A kit's box art, or a box icon when it has none.
struct KitThumbnail: View {
    let kit: Kit
    var size: CGFloat = 28

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: kit.picture?.id) {
            if let asset = kit.picture {
                image = await thumbnailStore?.thumbnail(assetID: asset.id, originalRelativePath: asset.originalRelativePath)
            } else {
                image = nil
            }
        }
    }
}

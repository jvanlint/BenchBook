import SwiftData
import SwiftUI

/// Shows a Reference's details and lets the user edit its title, tags and note.
struct ReferenceDetailsView: View {
    let reference: Reference

    @Environment(\.modelContext) private var modelContext
    @Environment(\.assetLibrary) private var assetLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imageSuggestionService) private var suggestions

    @State private var title: String
    @State private var tagsText: String
    @State private var note: String
    @State private var errorMessage: String?
    /// Existing tags Apple Intelligence thinks apply, for the user to add.
    @State private var suggestedTags: [String] = []
    /// The title and note before a suggestion filled them, for Undo.
    @State private var beforeSuggestion: (title: String, note: String)?
    @State private var suggestionError: String?

    init(reference: Reference) {
        self.reference = reference
        _title = State(initialValue: reference.title ?? "")
        _tagsText = State(initialValue: reference.tags.map(\.name).joined(separator: ", "))
        _note = State(initialValue: reference.note ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, prompt: Text(reference.displayTitle))
                TextField("Tags", text: $tagsText, prompt: Text("Separate tags with commas"))
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...8)
                if !suggestedTags.isEmpty {
                    LabeledContent("Suggested Tags") {
                        HStack {
                            ForEach(suggestedTags, id: \.self) { tag in
                                Button(tag, systemImage: "plus") { addTag(tag) }
                                    .help("Add the tag “\(tag)”")
                            }
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("Reference Details")
                        .font(.headline)
                    Spacer()
                    suggestButton
                }
            } footer: {
                suggestionFooter
            }

            if let text = reference.text {
                Section("Text") {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if reference.kind == .videoLink {
                VideoDetailsSection(reference: reference)
            }

            if reference.kind == .webpage {
                PageDetailsSection(reference: reference)
            }

            if reference.kind == .videoLink, let source = reference.sourcePageURL, !reference.videoMoments.isEmpty {
                Section("Moments") {
                    ForEach(reference.sortedVideoMoments) { moment in
                        Link(
                            moment.title ?? VideoLink.format(seconds: moment.offsetSeconds),
                            destination: VideoLink.playbackURL(for: source, at: moment.offsetSeconds)
                        )
                    }
                }
            }

            Section("Information") {
                LabeledContent("Type", value: reference.kind?.displayName ?? reference.kindRaw)
                LabeledContent("Added", value: reference.capturedAt.formatted(date: .abbreviated, time: .shortened))
                if let source = reference.sourcePageURL {
                    LabeledContent("Source") {
                        Link(source.host() ?? source.absoluteString, destination: source)
                    }
                }
                if let resource = reference.originalResourceURL {
                    LabeledContent("Original File") {
                        Link(resource.lastPathComponent, destination: resource)
                    }
                }
                if let asset = reference.asset {
                    if let filename = asset.originalFilename {
                        LabeledContent("File Name", value: filename)
                    }
                    LabeledContent("Size", value: asset.byteCount.formatted(.byteCount(style: .file)))
                    if let width = asset.pixelWidth, let height = asset.pixelHeight {
                        LabeledContent("Dimensions", value: "\(width) × \(height)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .alert(
            "Couldn't Save Reference",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Apple Intelligence

    private var offersSuggestions: Bool {
        reference.kind == .image && suggestions != nil && (suggestions?.availability().isOffered ?? false)
    }

    private var isSuggesting: Bool {
        suggestions?.inProgress.contains(reference.id) ?? false
    }

    @ViewBuilder
    private var suggestButton: some View {
        if offersSuggestions, let suggestions {
            if isSuggesting {
                ProgressView()
                    .controlSize(.small)
            } else {
                let reason = suggestions.availability().reason
                Button("Suggest Title and Note", systemImage: "sparkles", action: suggest)
                    .controlSize(.small)
                    .disabled(reason != nil)
                    .help(reason ?? "Describe this image with Apple Intelligence, on this Mac")
            }
        }
    }

    @ViewBuilder
    private var suggestionFooter: some View {
        if let suggestionError {
            Text(suggestionError)
                .foregroundStyle(.red)
        } else if beforeSuggestion != nil {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggested by Apple Intelligence on this Mac. Check details such as the variant or serial before saving.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo Suggestion", action: undoSuggestion)
                    .controlSize(.small)
            }
        }
    }

    private func suggest() {
        guard let suggestions else { return }
        suggestionError = nil
        Task {
            do {
                let suggestion = try await suggestions.suggestion(for: reference)
                if beforeSuggestion == nil { beforeSuggestion = (title, note) }
                if !suggestion.title.isEmpty { title = suggestion.title }
                if !suggestion.note.isEmpty { note = suggestion.note }
                let typed = Set(TagNames.parse(tagsText).map(TagNames.normalize))
                suggestedTags = suggestion.tags.filter { !typed.contains(TagNames.normalize($0)) }
            } catch {
                suggestionError = error.localizedDescription
            }
        }
    }

    private func undoSuggestion() {
        guard let before = beforeSuggestion else { return }
        title = before.title
        note = before.note
        suggestedTags = []
        beforeSuggestion = nil
    }

    private func addTag(_ tag: String) {
        let current = tagsText.trimmingCharacters(in: .whitespaces)
        tagsText = current.isEmpty ? tag : (current.hasSuffix(",") ? "\(current) \(tag)" : "\(current), \(tag)")
        suggestedTags.removeAll { $0 == tag }
    }

    private func save() {
        do {
            try ReferenceService(context: modelContext, library: assetLibrary)
                .updateDetails(reference, title: title, note: note, tagsText: tagsText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A video link's poster, channel, length, publish date and description.
private struct VideoDetailsSection: View {
    let reference: Reference

    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.linkInfoService) private var linkInfoService
    @State private var poster: NSImage?

    private var isFetching: Bool {
        linkInfoService?.inProgress.contains(reference.id) ?? false
    }

    var body: some View {
        Section {
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            if let channel = reference.videoChannel {
                LabeledContent("Channel") {
                    if let url = reference.videoChannelURL {
                        Link(channel, destination: url)
                    } else {
                        Text(channel)
                    }
                }
            }
            if let duration = reference.videoDurationSeconds {
                LabeledContent("Length", value: VideoLink.format(seconds: duration))
            }
            if let published = reference.videoPublishedAt {
                LabeledContent("Published", value: published.formatted(date: .abbreviated, time: .omitted))
            }
            if let description = reference.videoDescription {
                DisclosureGroup("Description") {
                    Text(description)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if reference.videoInfoFetchedAt == nil, !isFetching {
                Text("Video details haven't been fetched yet. BenchBook tries again when it's online.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Video")
                Spacer()
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                } else if let linkInfoService {
                    Button("Refresh") {
                        Task { await linkInfoService.refresh(reference) }
                    }
                    .controlSize(.small)
                    .help("Fetch the video's details and poster again")
                }
            }
        }
        .task(id: reference.videoInfoFetchedAt) {
            poster = await thumbnailStore?.poster(referenceID: reference.id, version: reference.videoInfoFetchedAt)
        }
    }
}


/// A webpage's preview image, site name and description.
private struct PageDetailsSection: View {
    let reference: Reference

    @Environment(\.thumbnailStore) private var thumbnailStore
    @Environment(\.linkInfoService) private var linkInfoService
    @State private var preview: NSImage?

    private var isFetching: Bool {
        linkInfoService?.inProgress.contains(reference.id) ?? false
    }

    var body: some View {
        Section {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: preview.looksLikeIcon ? 64 : .infinity, maxHeight: preview.looksLikeIcon ? 64 : 220)
                    .clipShape(RoundedRectangle(cornerRadius: preview.looksLikeIcon ? 12 : 6))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            if let site = reference.linkSiteName {
                LabeledContent("Site", value: site)
            }
            if let description = reference.linkDescription {
                Text(description)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if reference.linkPreviewFetchedAt == nil, !isFetching {
                Text("The page's preview hasn't been fetched yet. BenchBook tries again when it's online.")
                    .foregroundStyle(.secondary)
            } else if preview == nil, reference.linkSiteName == nil, reference.linkDescription == nil, !isFetching {
                Text("This page doesn't offer a preview.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Webpage")
                Spacer()
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                } else if let linkInfoService {
                    Button("Refresh") {
                        Task { await linkInfoService.refresh(reference) }
                    }
                    .controlSize(.small)
                    .help("Fetch the page's preview image and details again")
                }
            }
        }
        .task(id: reference.linkPreviewFetchedAt) {
            preview = await thumbnailStore?.poster(referenceID: reference.id, version: reference.linkPreviewFetchedAt)
        }
    }
}

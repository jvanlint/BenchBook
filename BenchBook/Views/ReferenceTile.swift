import SwiftUI

/// One Reference in the gallery: preview, title, type and tags.
struct ReferenceTile: View {
    let reference: Reference
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The preview sits in an overlay so a wide image fills and is
            // clipped to this box, instead of widening the tile.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .overlay { ReferencePreview(reference: reference) }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(reference.displayTitle)
                .lineLimit(2)

            Label(typeLine, systemImage: reference.kind?.systemImage ?? "questionmark.square")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !reference.tags.isEmpty {
                TagChips(names: reference.tags.map(\.name))
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(
            isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// e.g. "Image", "Video · 1:30", "Webpage · example.com".
    private var typeLine: String {
        let kindName = reference.kind?.displayName ?? String(localized: "Unknown Type")
        switch reference.kind {
        case .image:
            let count = reference.imageNotes.count
            if count > 0 {
                return "\(kindName) · " + String(localized: "\(count) notes")
            }
        case .videoLink:
            if let channel = reference.videoChannel {
                return "\(kindName) · \(channel)"
            }
            if let first = reference.sortedVideoMoments.first {
                return "\(kindName) · \(VideoLink.format(seconds: first.offsetSeconds))"
            }
        case .webpage, .textSnippet:
            if let host = reference.sourcePageURL?.host() {
                return "\(kindName) · \(host)"
            }
        default:
            break
        }
        return kindName
    }
}

private struct ReferencePreview: View {
    let reference: Reference

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var thumbnail: NSImage?

    var body: some View {
        content
            .task(id: previewKey) { await loadThumbnail() }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    if let duration = reference.videoDurationSeconds {
                        DurationBadge(seconds: duration)
                            .padding(6)
                    }
                }
        } else if reference.kind == .textSnippet || reference.kind == .note, let text = reference.text {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(7)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Image(systemName: reference.kind?.systemImage ?? "questionmark.square")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// Changes when there's a new file or poster to show.
    private var previewKey: String {
        "\(reference.asset?.id.uuidString ?? "")|\(reference.videoInfoFetchedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private func loadThumbnail() async {
        guard let thumbnailStore else { return }
        if let asset = reference.asset {
            thumbnail = await thumbnailStore.thumbnail(
                assetID: asset.id,
                originalRelativePath: asset.originalRelativePath
            )
        } else if reference.kind == .videoLink {
            thumbnail = await thumbnailStore.videoPoster(referenceID: reference.id, version: reference.videoInfoFetchedAt)
        }
    }
}

/// A video's length over its poster, e.g. "12:34".
struct DurationBadge: View {
    let seconds: Double

    var body: some View {
        Text(VideoLink.format(seconds: seconds))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Length \(VideoLink.format(seconds: seconds))")
    }
}

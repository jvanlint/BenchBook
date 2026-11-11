import SwiftUI

/// How a gallery tile shows that it's selected, as in Finder: every
/// selected tile in the accent colour while the gallery is active, and in
/// grey when it isn't.
enum TileHighlight: Equatable {
    case none
    case emphasized
    case unemphasized

    init(isSelected: Bool, galleryIsActive: Bool) {
        self = !isSelected ? .none : galleryIsActive ? .emphasized : .unemphasized
    }
}

/// One Reference in the gallery: preview, title, type and tags.
struct ReferenceTile: View {
    let reference: Reference
    var highlight: TileHighlight = .none

    private var isSelected: Bool { highlight != .none }
    /// Text on the accent colour is white.
    private var isOnAccent: Bool { highlight == .emphasized }

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
                .foregroundStyle(isOnAccent ? AnyShapeStyle(Self.textOnAccent) : AnyShapeStyle(.primary))

            Label(typeLine, systemImage: reference.kind?.systemImage ?? "questionmark.square")
                .font(.caption)
                .foregroundStyle(isOnAccent ? AnyShapeStyle(Self.textOnAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)

            if !reference.tags.isEmpty {
                TagChips(tags: reference.tags)
                    .padding(.top, 2)
                    .environment(\.backgroundProminence, isOnAccent ? .increased : .standard)
            }
        }
        .padding(8)
        .background(highlightColor, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    private var highlightColor: Color {
        switch highlight {
        case .none: .clear
        case .emphasized: Color(nsColor: .selectedContentBackgroundColor)
        case .unemphasized: Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
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
        case .pdf:
            let count = reference.markups.count
            if count > 0 {
                return "\(kindName) · " + String(localized: "\(count) markups")
            }
        case .videoLink:
            if let channel = reference.videoChannel {
                return "\(kindName) · \(channel)"
            }
            if let first = reference.sortedVideoMoments.first {
                return "\(kindName) · \(VideoLink.format(seconds: first.offsetSeconds))"
            }
        case .webpage, .textSnippet:
            if let site = reference.kind == .webpage ? reference.linkSiteName : nil {
                return "\(kindName) · \(site)"
            }
            if let host = reference.sourcePageURL?.host() {
                return "\(kindName) · \(host)"
            }
        default:
            break
        }
        return kindName
    }
}

/// A Reference's thumbnail, poster or text, or its type icon.
struct ReferencePreview: View {
    let reference: Reference
    var showsDuration = true
    /// Small previews show a site icon without the site's name.
    var isCompact = false

    @Environment(\.thumbnailStore) private var thumbnailStore
    @State private var thumbnail: NSImage?

    var body: some View {
        content
            .task(id: previewKey) { await loadThumbnail() }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail, reference.kind == .webpage, thumbnail.looksLikeIcon {
            siteIcon(thumbnail)
        } else if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    if showsDuration, let duration = reference.videoDurationSeconds {
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

    /// A site's icon at its own size, with the site's name.
    private func siteIcon(_ icon: NSImage) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: isCompact ? 28 : 56, height: isCompact ? 28 : 56)
                .clipShape(RoundedRectangle(cornerRadius: isCompact ? 6 : 12))
                .accessibilityHidden(true)
            if !isCompact, let site = reference.linkSiteName ?? reference.sourcePageURL?.host() {
                Text(site)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
    }

    /// Changes when there's a new file or poster to show.
    private var previewKey: String {
        "\(reference.asset?.id.uuidString ?? "")|\(reference.previewFetchedAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    private func loadThumbnail() async {
        guard let thumbnailStore else { return }
        if let asset = reference.asset {
            thumbnail = await thumbnailStore.thumbnail(
                assetID: asset.id,
                originalRelativePath: asset.originalRelativePath
            )
        } else if reference.hasFetchedPreview {
            thumbnail = await thumbnailStore.poster(referenceID: reference.id, version: reference.previewFetchedAt)
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

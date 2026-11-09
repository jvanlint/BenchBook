import AppKit
import Foundation
import Observation
import SwiftData

/// Fills in details and preview images for video links and webpages after
/// they're saved. Saving a link never waits for this; if BenchBook is
/// offline, the details are fetched the next time it launches.
@Observable
final class LinkInfoService {
    /// References being fetched now, so views can show progress.
    private(set) var inProgress = Set<UUID>()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let library: AssetLibrary
    @ObservationIgnored private let videoFetcher: VideoInfoFetcher
    @ObservationIgnored private let pageFetcher: PageInfoFetcher
    /// When false (turned off in Settings), nothing is fetched automatically;
    /// `refresh` still fetches when asked.
    @ObservationIgnored var fetchesAutomatically: () -> Bool = { AppSettings.fetchesLinkDetails() }

    init(
        context: ModelContext,
        library: AssetLibrary,
        fetcher: VideoInfoFetcher = VideoInfoFetcher(),
        pageFetcher: PageInfoFetcher = PageInfoFetcher()
    ) {
        self.context = context
        self.library = library
        self.videoFetcher = fetcher
        self.pageFetcher = pageFetcher
    }

    /// Fetches details for every video link and webpage that doesn't have them yet.
    func fetchMissing() {
        let video = ReferenceKind.videoLink.rawValue
        let webpage = ReferenceKind.webpage.rawValue
        let videos = FetchDescriptor<Reference>(
            predicate: #Predicate { $0.kindRaw == video && $0.videoInfoFetchedAt == nil }
        )
        let pages = FetchDescriptor<Reference>(
            predicate: #Predicate { $0.kindRaw == webpage && $0.linkPreviewFetchedAt == nil }
        )
        fetch(((try? context.fetch(videos)) ?? []) + ((try? context.fetch(pages)) ?? []))
    }

    /// Starts fetching in the background, unless turned off in Settings.
    func fetch(_ references: [Reference]) {
        let links = references.filter { $0.kind == .videoLink || $0.kind == .webpage }
        guard !links.isEmpty, fetchesAutomatically() else { return }
        Task {
            for reference in links {
                await refresh(reference)
            }
        }
    }

    /// Fetches details now, replacing any already stored.
    func refresh(_ reference: Reference) async {
        guard let source = reference.sourcePageURL, !inProgress.contains(reference.id) else { return }
        let posterURL = library.posterURL(referenceID: reference.id)
        let library = library

        switch reference.kind {
        case .videoLink:
            guard let video = VideoLink.parse(source) else { return }
            let fetcher = videoFetcher
            await run(on: reference) {
                let info = try await fetcher.info(for: video)
                if let data = await fetcher.thumbnail(for: info) {
                    Self.storePoster(data, at: posterURL, in: library)
                }
                return info
            } apply: { info in
                self.apply(info, to: reference)
            } markTried: {
                reference.videoInfoFetchedAt = .now
            }
        case .webpage:
            let fetcher = pageFetcher
            await run(on: reference) {
                let info = try await fetcher.info(for: source)
                if let preview = await fetcher.previewImage(for: info) {
                    Self.storePoster(preview.data, at: posterURL, in: library)
                }
                return info
            } apply: { info in
                self.apply(info, to: reference)
            } markTried: {
                reference.linkPreviewFetchedAt = .now
            }
        default:
            return
        }
    }

    /// Runs `work` off the main actor, then records the result. If no image
    /// downloads, any earlier one is kept.
    private func run<Info: Sendable>(
        on reference: Reference,
        work: @escaping @Sendable () async throws -> Info,
        apply: (Info) -> Void,
        markTried: () -> Void
    ) async {
        let id = reference.id
        inProgress.insert(id)
        defer { inProgress.remove(id) }

        let result: Result<Info, Error> = await Task.detached {
            do { return .success(try await work()) } catch { return .failure(error) }
        }.value

        // The Reference may have been deleted while waiting.
        guard reference.modelContext != nil, !reference.isDeleted else { return }

        switch result {
        case .success(let info):
            apply(info)
        case .failure(LinkInfoError.notFound):
            // Private, removed or refused: record the attempt so it isn't
            // retried at every launch. Refresh tries again.
            markTried()
        case .failure:
            return  // Offline or a server problem; try again next launch.
        }

        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    nonisolated private static func storePoster(_ data: Data, at url: URL, in library: AssetLibrary) {
        try? FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Copies fetched video details onto the Reference. Does not save.
    func apply(_ info: VideoInfo, to reference: Reference) {
        if let title = info.title, Self.shouldReplaceTitle(reference.title) {
            reference.title = title
        }
        reference.videoChannel = info.channel
        reference.videoChannelURL = info.channelURL
        reference.videoDurationSeconds = info.durationSeconds
        reference.videoPublishedAt = info.publishedAt
        reference.videoDescription = info.description
        reference.videoInfoFetchedAt = .now
        reference.updatedAt = .now
    }

    /// Copies fetched webpage details onto the Reference. Does not save.
    func apply(_ info: PageInfo, to reference: Reference) {
        if let title = info.title, Self.shouldReplaceTitle(reference.title, host: reference.sourcePageURL?.host()) {
            reference.title = title
        }
        reference.linkSiteName = info.siteName
        reference.linkDescription = info.description
        reference.linkPreviewFetchedAt = .now
        reference.updatedAt = .now
    }

    /// True for a missing title, a bare link or host, or a browser's video
    /// page title ("… - YouTube"); false for anything the user may have typed.
    static func shouldReplaceTitle(_ title: String?, host: String? = nil) -> Bool {
        guard let title = title?.trimmedOrNil else { return true }
        let lowered = title.lowercased()
        return lowered == "youtube" || lowered.hasSuffix(" - youtube") || lowered.hasSuffix(" on vimeo")
            || lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || (host.map { lowered == $0.lowercased() } ?? false)
    }
}

extension Reference {
    /// When the video poster or webpage preview was last fetched, so views
    /// know to reload it.
    var previewFetchedAt: Date? {
        kind == .webpage ? linkPreviewFetchedAt : videoInfoFetchedAt
    }

    /// Whether this kind of Reference can have a fetched poster or preview.
    var hasFetchedPreview: Bool {
        kind == .videoLink || kind == .webpage
    }
}

extension NSImage {
    /// A small square image, such as a site icon, which looks best shown at
    /// its own size rather than stretched to fill a tile.
    var looksLikeIcon: Bool {
        guard let rep = representations.first else { return false }
        return rep.pixelsWide == rep.pixelsHigh && rep.pixelsWide <= 256
    }
}

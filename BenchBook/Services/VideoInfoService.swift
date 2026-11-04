import Foundation
import Observation
import SwiftData

/// Fills in video links' details and poster images after they're saved.
/// Saving a link never waits for this; if BenchBook is offline, the details
/// are fetched the next time it launches.
@Observable
final class VideoInfoService {
    /// References being fetched now, so views can show progress.
    private(set) var inProgress = Set<UUID>()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let library: AssetLibrary
    @ObservationIgnored private let fetcher: VideoInfoFetcher

    init(context: ModelContext, library: AssetLibrary, fetcher: VideoInfoFetcher = VideoInfoFetcher()) {
        self.context = context
        self.library = library
        self.fetcher = fetcher
    }

    /// Fetches details for every video link that doesn't have them yet.
    func fetchMissing() {
        let video = ReferenceKind.videoLink.rawValue
        let descriptor = FetchDescriptor<Reference>(
            predicate: #Predicate { $0.kindRaw == video && $0.videoInfoFetchedAt == nil }
        )
        fetch((try? context.fetch(descriptor)) ?? [])
    }

    /// Starts fetching in the background.
    func fetch(_ references: [Reference]) {
        let videos = references.filter { $0.kind == .videoLink }
        guard !videos.isEmpty else { return }
        Task {
            for reference in videos {
                await refresh(reference)
            }
        }
    }

    /// Fetches details now, replacing any already stored.
    func refresh(_ reference: Reference) async {
        guard reference.kind == .videoLink,
              let source = reference.sourcePageURL,
              let video = VideoLink.parse(source),
              !inProgress.contains(reference.id)
        else { return }
        let id = reference.id
        inProgress.insert(id)
        defer { inProgress.remove(id) }

        let fetcher = fetcher
        let library = library
        let result: Result<VideoInfo, Error> = await Task.detached {
            do { return .success(try await fetcher.info(for: video)) } catch { return .failure(error) }
        }.value

        // The Reference may have been deleted while waiting.
        guard reference.modelContext != nil, !reference.isDeleted else { return }

        switch result {
        case .success(let info):
            let posterURL = library.videoPosterURL(referenceID: id)
            // If no poster downloads, any earlier one is kept.
            await Task.detached {
                guard let data = await fetcher.thumbnail(for: info) else { return }
                try? FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
                try? data.write(to: posterURL, options: .atomic)
            }.value
            guard reference.modelContext != nil, !reference.isDeleted else { return }
            apply(info, to: reference)
        case .failure(VideoInfoError.notFound):
            // Private or removed: record the attempt so it isn't retried at every launch.
            reference.videoInfoFetchedAt = .now
        case .failure:
            return  // Offline or a server problem; try again next launch.
        }

        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    /// Copies fetched details onto the Reference. Does not save.
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

    /// True for a missing title or a browser's page title ("… - YouTube"),
    /// false for anything the user may have typed.
    static func shouldReplaceTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmedOrNil else { return true }
        let lowered = title.lowercased()
        return lowered == "youtube" || lowered.hasSuffix(" - youtube") || lowered.hasSuffix(" on vimeo")
            || lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}

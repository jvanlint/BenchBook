import Foundation
import Observation
import OSLog
import SwiftData

/// Asks Apple Intelligence for image titles and notes: on request from the
/// details sheet, or for new images when turned on in Settings.
@Observable
final class ImageSuggestionService {
    /// Images being described now, so views can show progress.
    private(set) var inProgress = Set<UUID>()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let library: AssetLibrary
    @ObservationIgnored private let suggester: (any ImageSuggester)?
    @ObservationIgnored private let readText: @Sendable (URL) -> [String]
    @ObservationIgnored var availability: () -> ImageSuggestionAvailability
    /// Off unless turned on in Settings.
    @ObservationIgnored var suggestsAutomatically: () -> Bool = { AppSettings.suggestsImageDetails() }

    init(
        context: ModelContext,
        library: AssetLibrary,
        suggester: (any ImageSuggester)? = nil,
        availability: (() -> ImageSuggestionAvailability)? = nil,
        readText: @escaping @Sendable (URL) -> [String] = ImageTextReader.recognizedText(in:)
    ) {
        self.context = context
        self.library = library
        self.readText = readText
        if let suggester {
            self.suggester = suggester
            self.availability = availability ?? { .available }
        } else if #available(macOS 27.0, *) {
            self.suggester = AppleIntelligenceSuggester()
            self.availability = availability ?? { .current }
        } else {
            self.suggester = nil
            self.availability = { .unsupportedSystem }
        }
    }

    /// Suggests a title, note and tags for an image, without changing it.
    func suggestion(for reference: Reference) async throws -> ImageSuggestion {
        if let reason = availability().reason { throw ImageSuggestionError(message: reason) }
        guard let suggester, reference.kind == .image, let asset = reference.asset else {
            throw ImageSuggestionError(message: String(localized: "Suggestions are only available for images."))
        }
        let id = reference.id
        inProgress.insert(id)
        defer { inProgress.remove(id) }

        let imageURL = library.url(forRelativePath: asset.originalRelativePath)
        let readText = readText
        let text = await Task.detached(priority: .userInitiated) { readText(imageURL) }.value
        let tagNames = try context.fetch(FetchDescriptor<Tag>()).map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let prompt = ImageSuggestionRules.prompt(
            recognizedText: text, tagNames: tagNames, projectHint: ImageSuggestionRules.projectHint(for: reference.project)
        )
        let raw = try await suggester.suggest(imageURL: imageURL, prompt: prompt)
        return ImageSuggestionRules.cleaned(raw, tagNames: tagNames, existingTags: reference.tags.map(\.name))
    }

    /// For new images, when turned on: fills an empty title and note in the
    /// background. Text the user wrote is never replaced.
    func suggestForNewImages(_ references: [Reference]) {
        let images = references.filter { reference in
            reference.kind == .image && (reference.title?.trimmedOrNil == nil || reference.note?.trimmedOrNil == nil)
        }
        guard !images.isEmpty, suggestsAutomatically(), availability().isAvailable else { return }
        Task {
            for reference in images {
                await fillEmptyFields(of: reference)
            }
        }
    }

    private func fillEmptyFields(of reference: Reference) async {
        do {
            let suggestion = try await suggestion(for: reference)
            // The reference may have been deleted or edited meanwhile.
            guard reference.modelContext != nil, !reference.isDeleted else { return }
            if ImageSuggestionRules.fillEmptyFields(of: reference, with: suggestion) {
                try context.save()
            }
        } catch {
            Logger.capture.info("No suggestion for an image: \(error.localizedDescription, privacy: .public)")
        }
    }
}

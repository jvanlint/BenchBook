import Foundation
import FoundationModels

extension ImageSuggestionAvailability {
    /// Whether this Mac's on-device model can describe images now.
    static var current: ImageSuggestionAvailability {
        guard #available(macOS 27.0, *) else { return .unsupportedSystem }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision)
                ? .available
                : .unavailable(String(localized: "This Mac's Apple Intelligence model can't describe images."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(String(localized: "Turn on Apple Intelligence in System Settings to get suggestions."))
        case .unavailable(.modelNotReady):
            return .unavailable(String(localized: "Apple Intelligence is still getting ready. Try again later."))
        case .unavailable(.deviceNotEligible):
            return .unavailable(String(localized: "This Mac doesn't support Apple Intelligence."))
        case .unavailable:
            return .unavailable(String(localized: "Apple Intelligence isn't available right now."))
        }
    }
}

/// Suggestions from the on-device Apple Intelligence model. The image never
/// leaves the Mac.
@available(macOS 27.0, *)
nonisolated struct AppleIntelligenceSuggester: ImageSuggester {
    @Generable
    struct Output {
        @Guide(description: "A short title that names the aircraft, vehicle or ship type and what the photo shows, at most 8 words, no ending full stop")
        var title: String
        @Guide(description: "One to three sentences describing what's visible that a modeller would want to remember")
        var note: String
        @Guide(description: "Tags that clearly apply, chosen only from the given list", .maximumCount(3))
        var tags: [String]
    }

    func suggest(imageURL: URL, prompt: String) async throws -> ImageSuggestion {
        let session = LanguageModelSession(model: .default, instructions: ImageSuggestionRules.instructions)
        do {
            let response = try await session.respond(generating: Output.self) {
                prompt
                Attachment(imageURL: imageURL)
            }
            return ImageSuggestion(title: response.content.title, note: response.content.note, tags: response.content.tags)
        } catch let error as LanguageModelSession.GenerationError {
            throw ImageSuggestionError(error)
        }
    }
}

/// Generation failures, in words for the user.
nonisolated struct ImageSuggestionError: LocalizedError, Equatable {
    let errorDescription: String?

    init(message: String) {
        errorDescription = message
    }

    @available(macOS 27.0, *)
    init(_ error: LanguageModelSession.GenerationError) {
        switch error {
        case .guardrailViolation:
            errorDescription = String(localized: "Apple Intelligence wouldn't describe this image.")
        case .unsupportedLanguageOrLocale:
            errorDescription = String(localized: "Apple Intelligence doesn't support your language yet.")
        case .assetsUnavailable:
            errorDescription = String(localized: "Apple Intelligence is still getting ready. Try again later.")
        default:
            errorDescription = String(localized: "Apple Intelligence couldn't suggest details for this image.")
        }
    }
}

import Foundation
import Vision

/// A title, note and tags suggested for an image by Apple Intelligence.
nonisolated struct ImageSuggestion: Equatable, Sendable {
    var title: String
    var note: String
    /// Names of the user's existing tags; never new ones.
    var tags: [String] = []
}

/// Suggests details for an image. The real one uses the on-device model;
/// tests use a stub.
protocol ImageSuggester: Sendable {
    /// `prompt` is the text part, from `ImageSuggestionRules.prompt`.
    func suggest(imageURL: URL, prompt: String) async throws -> ImageSuggestion
}

/// Whether suggestions can be made on this Mac, and if not, why.
nonisolated enum ImageSuggestionAvailability: Equatable, Sendable {
    case available
    /// Before macOS 27: the feature isn't offered at all.
    case unsupportedSystem
    /// macOS 27, but the model can't be used right now.
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    /// Whether to show the feature (perhaps disabled, with the reason).
    var isOffered: Bool { self != .unsupportedSystem }

    var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}

/// The rules around suggestions, kept apart from the model so they're testable.
nonisolated enum ImageSuggestionRules {
    static let maximumTitleLength = 80
    static let maximumNoteLength = 400
    static let maximumTags = 3

    static let instructions = """
        You help a scale modeller label the reference photos they collect for a build: real aircraft, \
        vehicles, ships and figures, kits, box art, instructions, decal sheets and painted models. \
        Name the aircraft, vehicle or ship type in the title whenever you can recognise it, for example \
        "F-16 Fighting Falcon" or "Spitfire Mk IX". The build project's details are a strong hint: \
        most photos in a project show its subject, so use that name if the image fits it. \
        In the note, describe what's visible: the part of the subject shown, colours, markings, \
        weathering and details worth copying. Only leave out a sub-variant, serial or unit that you \
        can't read in the image or confirm from the project.
        """

    /// The build a reference belongs to, as a hint, e.g.
    /// "F-16C (Tamiya · 1:48 · F-16CJ Block 50), markings: 52nd FW".
    @MainActor
    static func projectHint(for project: Project?) -> String? {
        guard let project else { return nil }
        var hint = project.name
        if !project.summary.isEmpty { hint += " (\(project.summary))" }
        if let markings = project.markingsScheme?.trimmedOrNil { hint += ", markings: \(markings)" }
        return hint
    }

    /// The text part of the prompt; the image is attached separately.
    static func prompt(recognizedText: [String], tagNames: [String], projectHint: String? = nil) -> String {
        var lines = ["Suggest a short title and a note for this reference image."]
        if let projectHint {
            lines.append("It was saved to the build project: \(projectHint.prefix(200))")
        }
        let text = recognizedText.prefix(20).joined(separator: " | ")
        if !text.isEmpty {
            lines.append("Text visible in the image: \(text.prefix(600))")
        }
        if tagNames.isEmpty {
            lines.append("Don't suggest any tags.")
        } else {
            lines.append("Choose up to \(maximumTags) tags that clearly apply, only from this list: \(tagNames.prefix(150).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// Trims the suggestion, limits its length, and keeps only tags from
    /// `tagNames` (in their own spelling) that the image doesn't already have.
    static func cleaned(_ suggestion: ImageSuggestion, tagNames: [String], existingTags: [String] = []) -> ImageSuggestion {
        let known = Dictionary(tagNames.map { (TagNames.normalize($0), $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(existingTags.map(TagNames.normalize))
        var seen = Set<String>()
        let tags = suggestion.tags.compactMap { name -> String? in
            let key = TagNames.normalize(name)
            guard let canonical = known[key], !existing.contains(key), seen.insert(key).inserted else { return nil }
            return canonical
        }
        return ImageSuggestion(
            title: clip(suggestion.title, to: maximumTitleLength),
            note: clip(suggestion.note, to: maximumNoteLength),
            tags: Array(tags.prefix(maximumTags))
        )
    }

    /// Fills the reference's title and note only where they're empty, so
    /// nothing the user wrote is replaced. Tags are never added automatically.
    /// Returns whether anything changed.
    @MainActor
    @discardableResult
    static func fillEmptyFields(of reference: Reference, with suggestion: ImageSuggestion) -> Bool {
        var changed = false
        if reference.title?.trimmedOrNil == nil, let title = suggestion.title.trimmedOrNil {
            reference.title = title
            changed = true
        }
        if reference.note?.trimmedOrNil == nil, let note = suggestion.note.trimmedOrNil {
            reference.note = note
            changed = true
        }
        if changed { reference.updatedAt = .now }
        return changed
    }

    private static func clip(_ text: String, to length: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > length else { return trimmed }
        return String(trimmed.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Reads text in an image (serials, codes, box art) with Vision, on device.
nonisolated enum ImageTextReader {
    static func recognizedText(in imageURL: URL) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(url: imageURL)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.4 }
            .map(\.string)
            .filter { $0.count >= 2 }
    }
}

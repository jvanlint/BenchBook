import Foundation
import SwiftData
import Testing
@testable import BenchBook

/// Returns a fixed suggestion and records what it was asked.
private final class StubSuggester: ImageSuggester, @unchecked Sendable {
    let result: ImageSuggestion
    private let lock = NSLock()
    private var calls: [String] = []

    init(_ result: ImageSuggestion) { self.result = result }

    /// The prompts it was given.
    var requests: [String] { lock.withLock { calls } }

    func suggest(imageURL: URL, prompt: String) async throws -> ImageSuggestion {
        lock.withLock { calls.append(prompt) }
        return result
    }
}

struct ImageSuggestionRulesTests {
    @Test func promptListsTextAndTags() {
        let prompt = ImageSuggestionRules.prompt(recognizedText: ["USAF", "91-0338"], tagNames: ["cockpit", "decals"])
        #expect(prompt.contains("Text visible in the image: USAF | 91-0338"))
        #expect(prompt.contains("only from this list: cockpit, decals"))

        let plain = ImageSuggestionRules.prompt(recognizedText: [], tagNames: [])
        #expect(!plain.contains("Text visible"))
        #expect(!plain.contains("build project"))
        #expect(plain.contains("Don't suggest any tags."))
    }

    @MainActor
    @Test func projectDetailsAreAHint() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16C", in: container.mainContext)
        #expect(ImageSuggestionRules.projectHint(for: project) == "F-16C")
        project.manufacturer = "Tamiya"
        project.scale = "1:48"
        project.subject = "F-16CJ Block 50"
        project.markingsScheme = "52nd FW, Spangdahlem"
        let hint = try #require(ImageSuggestionRules.projectHint(for: project))
        #expect(hint == "F-16C (Tamiya · 1:48 · F-16CJ Block 50), markings: 52nd FW, Spangdahlem")
        #expect(ImageSuggestionRules.prompt(recognizedText: [], tagNames: [], projectHint: hint)
            .contains("It was saved to the build project: F-16C (Tamiya"))
        #expect(ImageSuggestionRules.projectHint(for: nil) == nil)
    }

    @Test func keepsOnlyKnownNewTagsAndTrims() {
        let raw = ImageSuggestion(
            title: "  F-16C on the ramp \n",
            note: String(repeating: "a", count: 500),
            tags: ["COCKPIT", "weathering", "brand new tag", "Decals", "cockpit", "markings"]
        )
        let cleaned = ImageSuggestionRules.cleaned(
            raw, tagNames: ["Cockpit", "Decals", "weathering", "markings"], existingTags: ["decals"]
        )
        #expect(cleaned.title == "F-16C on the ramp")
        #expect(cleaned.note.count == ImageSuggestionRules.maximumNoteLength)
        #expect(cleaned.note.hasSuffix("…"))
        // Their own spelling; no new tags, no tags it already has, no repeats; at most three.
        #expect(cleaned.tags == ["Cockpit", "weathering", "markings"])
    }

    @MainActor
    @Test func fillsOnlyEmptyFields() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let project = Fixtures.makeProject("F-16", in: container.mainContext)
        let suggestion = ImageSuggestion(title: "Grey fighter", note: "Weathered panels.")

        let empty = Reference(project: project, kind: .image)
        #expect(ImageSuggestionRules.fillEmptyFields(of: empty, with: suggestion))
        #expect(empty.title == "Grey fighter")
        #expect(empty.note == "Weathered panels.")

        let written = Reference(project: project, kind: .image, title: "My intake photo", note: "  ")
        #expect(ImageSuggestionRules.fillEmptyFields(of: written, with: suggestion))
        #expect(written.title == "My intake photo")
        #expect(written.note == "Weathered panels.")

        let done = Reference(project: project, kind: .image, title: "Mine", note: "Also mine")
        #expect(!ImageSuggestionRules.fillEmptyFields(of: done, with: suggestion))
        #expect(done.title == "Mine" && done.note == "Also mine")
    }
}

@MainActor
struct ImageSuggestionServiceTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url)
        container = try Fixtures.makeInMemoryContainer()
    }

    private func importImage(into project: Project, tags: [String] = []) async throws -> Reference {
        let file = try Fixtures.writePNG(to: folder.file("photo.png"), width: 40, height: 30)
        let outcomes = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: file, originalFilename: "photo.png", resourceURL: nil)], into: project, tags: tags)
        guard case .added(let reference) = try #require(outcomes.first) else { throw CocoaError(.fileReadUnknown) }
        return reference
    }

    @Test func suggestsWithReadTextAndExistingTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let image = try await importImage(into: project, tags: ["Cockpit"])
        try TagService(context: context).addTags(named: "decals", to: [image])
        let stub = StubSuggester(ImageSuggestion(title: "Ejection seat", note: "Grey seat.", tags: ["cockpit", "seat belts"]))
        let service = ImageSuggestionService(context: context, library: library, suggester: stub, readText: { _ in ["ACES II"] })

        let suggestion = try await service.suggestion(for: image)

        let prompt = try #require(stub.requests.first)
        #expect(prompt.contains("Text visible in the image: ACES II"))
        #expect(prompt.contains("only from this list: Cockpit, decals"))
        #expect(prompt.contains("It was saved to the build project: F-16"))
        // "Cockpit" is already on the image and "seat belts" isn't a tag.
        #expect(suggestion == ImageSuggestion(title: "Ejection seat", note: "Grey seat.", tags: []))
        // Asking never changes the reference.
        #expect(image.title == nil)
        #expect(service.inProgress.isEmpty)
    }

    @Test func explainsWhenUnavailable() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let image = try await importImage(into: project)
        let service = ImageSuggestionService(
            context: context, library: library, suggester: StubSuggester(ImageSuggestion(title: "x", note: "y")),
            availability: { .unavailable("Turn on Apple Intelligence.") }, readText: { _ in [] }
        )
        await #expect(throws: ImageSuggestionError(message: "Turn on Apple Intelligence.")) {
            try await service.suggestion(for: image)
        }
    }

    @Test func automaticModeIsOffByDefaultAndFillsOnlyEmptyFields() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let image = try await importImage(into: project)
        image.note = "My note"
        try context.save()
        let stub = StubSuggester(ImageSuggestion(title: "Grey fighter", note: "Suggested note"))
        let service = ImageSuggestionService(context: context, library: library, suggester: stub, readText: { _ in [] })

        service.suggestsAutomatically = { false }
        service.suggestForNewImages([image])
        try await Task.sleep(for: .milliseconds(200))
        #expect(stub.requests.isEmpty)

        service.suggestsAutomatically = { true }
        service.suggestForNewImages([image])
        for _ in 0..<50 where image.title == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(image.title == "Grey fighter")
        #expect(image.note == "My note")
        #expect(!context.hasChanges)

        // Nothing left to fill: not asked again.
        service.suggestForNewImages([image])
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == 1)
    }

    @Test func defaultSettingIsOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "BenchBookTests-\(UUID().uuidString)"))
        #expect(!AppSettings.suggestsImageDetails(in: defaults))
    }
}

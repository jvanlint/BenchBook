import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct SearchQueryTests {
    @Test func matchesIgnoringCaseAccentsAndPunctuation() {
        let query = SearchQuery(text: "f16 décal")
        let fields = [SearchField("F-16CJ Viper"), SearchField("Decal placement guide")]
        #expect(query.matchesEveryWord(in: fields))
        #expect(!query.matchesEveryWord(in: [SearchField("F-16CJ Viper")]))  // every word must match
        #expect(SearchQuery(text: "36270").matchesEveryWord(in: [SearchField("FS 36270")]))
        #expect(SearchQuery(text: "xf54").matchesEveryWord(in: [SearchField("XF-54")]))
        #expect(SearchQuery(text: "  ").isEmpty)
        #expect(!SearchQuery(text: "", tags: ["cockpit"]).isEmpty)
    }

    @Test func excerptsAroundTheMatch() {
        let text = String(repeating: "Filler words here. ", count: 10) + "The seat belts are HGW fabric.\nMore text."
        let excerpt = String(SearchSnippet.excerpt(of: text, for: SearchQuery(text: "belts")).characters)
        #expect(excerpt.hasPrefix("…"))
        #expect(excerpt.contains("seat belts are HGW fabric. More text."))

        let highlighted = SearchSnippet.highlighted("Seat Belts", for: SearchQuery(text: "belts"))
        let bold = highlighted.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(highlighted[$0.range].characters) }
        #expect(bold == ["Belts"])
    }
}

@MainActor
struct SearchIndexTests {
    let container: ModelContainer
    let folder: TemporaryFolder
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
        folder = try TemporaryFolder()
    }

    private func reference(_ kind: ReferenceKind, in project: Project, title: String? = nil, text: String? = nil,
                           tags: [String] = []) throws -> Reference {
        let reference = Reference(project: project, kind: kind, title: title, text: text)
        context.insert(reference)
        try ReferenceService(context: context, library: AssetLibrary(rootURL: folder.url)).setTags(tags, on: reference)
        try context.save()
        return reference
    }

    @Test func findsAcrossProjectsPaintsAndImageMarkups() throws {
        let spitfire = Fixtures.makeProject("Spitfire Mk IX", in: context)
        let f16 = Fixtures.makeProject("F-16CJ", in: context)
        let photo = try reference(.image, in: spitfire, title: "Cockpit walkaround", tags: ["cockpit"])
        context.insert(ImageNote(reference: photo, x: 0, y: 0, width: 0.1, height: 0.1, text: "Throttle quadrant"))
        let seat = ImageNote(reference: photo, x: 0.5, y: 0.5, width: 0.1, height: 0.1, text: "Seat belts are Sutton harness")
        context.insert(seat)
        _ = try reference(.note, in: f16, title: "Seat", text: "ACES II seat, belts in olive drab")
        _ = try reference(.webpage, in: f16, title: "Intake covers")
        try PaintService(context: context).createPaint(from: {
            var draft = PaintDraft()
            draft.brand = "Mr. Color"
            draft.code = "C307"
            draft.standardCode = "FS 36320"
            return draft
        }())
        try context.save()

        let index = SearchIndex(context: context)

        // A box's text finds its image, and says which box.
        let belts = index.search(SearchQuery(text: "belts"))
        #expect(belts.referenceGroups.map(\.project.name) == ["F-16CJ", "Spitfire Mk IX"])
        let hit = try #require(belts.referenceGroups.last?.hits.first)
        #expect(hit.reference.id == photo.id)
        #expect(hit.matches.map(\.kind) == [.imageNote(id: seat.id, number: 2)])

        // Words can match different parts of the same reference.
        let cockpitSeat = index.search(SearchQuery(text: "cockpit sutton"))
        #expect(cockpitSeat.referenceGroups.flatMap(\.hits).map(\.reference.id) == [photo.id])

        // Paints and projects are found too.
        let grey = index.search(SearchQuery(text: "36320"))
        #expect(grey.paints.map(\.code) == ["C307"])
        #expect(index.search(SearchQuery(text: "spitfire")).projects.map(\.name) == ["Spitfire Mk IX"])

        // A tag token narrows to tagged references only.
        let tagged = index.search(SearchQuery(text: "seat", tags: ["cockpit"]))
        #expect(tagged.referenceGroups.flatMap(\.hits).map(\.reference.id) == [photo.id])
        #expect(tagged.paints.isEmpty && tagged.projects.isEmpty)

        #expect(index.search(SearchQuery(text: "canopy")).isEmpty)
    }

    @Test func refreshesAfterSaving() throws {
        let project = Fixtures.makeProject("Bf 109", in: context)
        let index = SearchIndex(context: context)
        #expect(index.search(SearchQuery(text: "spinner")).isEmpty)

        let generation = index.generation
        _ = try reference(.note, in: project, text: "Spinner spiral is white")
        #expect(index.generation > generation)
        #expect(index.search(SearchQuery(text: "spinner")).referenceCount == 1)
    }

    @Test func titleMatchesComeFirst() throws {
        let project = Fixtures.makeProject("P-51D", in: context)
        let older = try reference(.note, in: project, title: "Wheel wells", text: "Zinc chromate")
        older.capturedAt = .now.addingTimeInterval(-60)
        let newer = try reference(.note, in: project, title: "Interior", text: "Wheel well doors")
        try context.save()

        let hits = SearchIndex(context: context).search(SearchQuery(text: "wheel")).referenceGroups.first?.hits
        #expect(hits?.map(\.reference.id) == [older.id, newer.id])
    }
}

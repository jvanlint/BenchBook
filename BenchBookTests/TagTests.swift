import CoreTransferable
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BenchBook

@MainActor
struct TagServiceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: TagService { TagService(context: context) }

    init() throws {
        container = try Fixtures.makeInMemoryContainer()
    }

    private func references(_ count: Int) throws -> [Reference] {
        let project = Fixtures.makeProject("Spitfire", in: context)
        let made = (0..<count).map { index in
            let reference = Reference(project: project, kind: .note, text: "Note \(index)")
            context.insert(reference)
            return reference
        }
        try context.save()
        return made
    }

    private func tagNames(_ reference: Reference) -> [String] {
        reference.tags.map(\.name)
    }

    @Test func tagsManyReferencesAtOnce() throws {
        let refs = try references(3)
        try service.addTags(named: "Cockpit, seat belts , cockpit", to: [refs[0], refs[1]])
        let cockpit = try #require(try service.existingTag(named: "cockpit"))

        #expect(tagNames(refs[0]) == ["Cockpit", "seat belts"])
        #expect(service.state(of: cockpit, on: refs) == .some)
        #expect(service.state(of: cockpit, on: [refs[0], refs[1]]) == .all)

        // Toggling a partly applied tag adds it to the rest...
        try service.toggle(cockpit, on: refs)
        #expect(service.state(of: cockpit, on: refs) == .all)
        #expect(cockpit.usageCount == 3)
        // ...and toggling it again removes it from all.
        try service.toggle(cockpit, on: refs)
        #expect(service.state(of: cockpit, on: refs) == .none)
        #expect(try context.fetchCount(FetchDescriptor<BenchBook.Tag>()) == 2)  // the tag itself stays
    }

    @Test func renamesAndMergesOnCollision() throws {
        let refs = try references(3)
        try service.addTags(named: "seatbelts", to: [refs[0], refs[1]])
        try service.addTags(named: "Harness", to: [refs[1], refs[2]])
        let seatbelts = try #require(try service.existingTag(named: "seatbelts"))
        let harness = try #require(try service.existingTag(named: "harness"))
        try service.setColor(.orange, for: [seatbelts])

        try service.rename(harness, to: "  Seat  Belts ")
        #expect(harness.name == "Seat Belts")
        #expect(harness.normalizedName == "seat belts")

        // Renaming onto an existing name merges, without doubling up refs[1].
        let merged = try service.rename(harness, to: "SEATBELTS")
        #expect(merged.id == seatbelts.id)
        #expect(merged.name == "SEATBELTS")
        #expect(merged.usageCount == 3)
        #expect(merged.tagColor == .orange)
        #expect(refs.map(tagNames) == [["SEATBELTS"], ["SEATBELTS"], ["SEATBELTS"]])
        #expect(try context.fetchCount(FetchDescriptor<BenchBook.Tag>()) == 1)

        #expect(throws: TagError.emptyName) { try service.rename(merged, to: " , ") }
    }

    @Test func mergesSeveralTags() throws {
        let refs = try references(3)
        try service.addTags(named: "cockpit", to: [refs[0]])
        try service.addTags(named: "office", to: [refs[0], refs[1]])
        try service.addTags(named: "pit", to: [refs[2]])
        let tags = try context.fetch(FetchDescriptor<BenchBook.Tag>())
        let cockpit = try #require(tags.first { $0.name == "cockpit" })
        try service.setColor(.blue, for: tags.filter { $0.name == "pit" })

        try service.merge(tags, into: cockpit)

        #expect(cockpit.usageCount == 3)
        #expect(cockpit.tagColor == .blue)  // took a colour it lacked
        #expect(try context.fetchCount(FetchDescriptor<BenchBook.Tag>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ReferenceTag>()) == 3)
    }

    @Test func deletesTagsButNotReferences() throws {
        let refs = try references(2)
        try service.addTags(named: "decals, wheels", to: refs)
        let decals = try #require(try service.existingTag(named: "decals"))
        try service.createTag(named: "unused one")

        try service.delete([decals])
        #expect(refs.map(tagNames) == [["wheels"], ["wheels"]])
        #expect(try context.fetchCount(FetchDescriptor<Reference>()) == 2)

        #expect(try service.removeUnused() == 1)
        #expect(try context.fetch(FetchDescriptor<BenchBook.Tag>()).map(\.name) == ["wheels"])
    }

    @Test func ordersByUsage() throws {
        let refs = try references(3)
        try service.addTags(named: "b", to: refs)
        try service.addTags(named: "a", to: [refs[0]])
        try service.addTags(named: "c", to: [refs[0]])
        let sorted = try context.fetch(FetchDescriptor<BenchBook.Tag>()).sorted(by: BenchBook.Tag.byUsage).map(\.name)
        #expect(sorted == ["b", "a", "c"])
    }
}

/// Dragged tags and References travel as BenchBook's own types, never as
/// text the window would capture.
struct TagDragTests {
    @Test func dragItemsRoundTripThroughItemProviders() async throws {
        let tagID = UUID()
        let tagProvider = NSItemProvider()
        tagProvider.register(TagDragItem(tagID: tagID))
        #expect(tagProvider.registeredTypeIdentifiers == ["com.jasonvanlint.benchbook.tag"])
        #expect(!tagProvider.hasItemConformingToTypeIdentifier("public.plain-text"))
        let tag = try await withCheckedThrowingContinuation { continuation in
            _ = tagProvider.loadTransferable(type: TagDragItem.self) { continuation.resume(with: $0) }
        }
        #expect(tag.tagID == tagID)

        let ids = [UUID(), UUID()]
        let referencesProvider = NSItemProvider()
        referencesProvider.register(ReferencesDragItem(referenceIDs: ids))
        #expect(!PasteRouter.supportedTypes.contains { referencesProvider.hasItemConformingToTypeIdentifier($0.identifier) })
        let references = try await withCheckedThrowingContinuation { continuation in
            _ = referencesProvider.loadTransferable(type: ReferencesDragItem.self) { continuation.resume(with: $0) }
        }
        #expect(references.referenceIDs == ids)
    }
}

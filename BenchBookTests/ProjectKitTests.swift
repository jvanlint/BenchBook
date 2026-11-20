import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct KitDetailsNoteTests {
    @Test func listsOnlyTheFilledInParts() {
        #expect(KitDetailsNote.line(manufacturer: "Italeri", number: "1234", scale: "1:72") == "Kit: Italeri · 1234 · 1:72")
        #expect(KitDetailsNote.line(manufacturer: " ", number: nil, scale: "1:48") == "Kit: 1:48")
        #expect(KitDetailsNote.line(manufacturer: "", number: " ", scale: "") == nil)
    }

    @Test func goesAtTheEndOfTheNotesOnce() {
        let line = "Kit: Italeri · 1234 · 1:72"
        #expect(KitDetailsNote.notes(nil, adding: line) == line)
        #expect(KitDetailsNote.notes("  ", adding: line) == line)
        #expect(KitDetailsNote.notes("Wheel wells\n", adding: line) == "Wheel wells\n\n" + line)
        let once = "Wheel wells\n\n" + line
        #expect(KitDetailsNote.notes(once, adding: line) == once)
        #expect(KitDetailsNote.notes("Wheel wells", adding: nil) == "Wheel wells")
    }
}

@MainActor
struct ProjectKitMigrationTests {
    private typealias Old = BenchBookSchemaV3

    /// Writes a schema 3 library: four projects and a kit in the catalogue.
    private func makeSchemaThreeLibrary(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: Old.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let context = container.mainContext
        let full = Old.Project(name: "Cobra", manufacturer: "Italeri", subject: "AH-1W", scale: "1:72", kitNumber: "1234",
                               notes: "Wheel wells")
        full.statusRaw = "completed"
        context.insert(full)
        context.insert(Old.Project(name: "Spitfire", scale: "1:48"))
        context.insert(Old.Project(name: "Someday", notes: "Ideas only"))
        // As if an earlier upgrade stopped after writing the notes.
        context.insert(Old.Project(name: "Again", manufacturer: "Revell", notes: "Kit: Revell"))
        context.insert(Old.Kit(brand: "Italeri", name: "Super Cobra", scale: "1:72", number: "1234"))
        context.insert(Old.Reference(project: full, kind: .note, text: "Cockpit green"))
        try context.save()
    }

    @Test func kitDetailsMoveToTheNotesAndNoKitsAreMade() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")
        try makeSchemaThreeLibrary(at: storeURL)

        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let context = container.mainContext
        let projects = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Project>()).map { ($0.name, $0) })
        #expect(projects.count == 4)
        #expect(projects["Cobra"]?.notes == "Wheel wells\n\nKit: Italeri · 1234 · 1:72")
        #expect(projects["Cobra"]?.subject == "AH-1W")
        #expect(projects["Cobra"]?.status == .completed)
        #expect(projects["Cobra"]?.references.first?.text == "Cockpit green")
        #expect(projects["Spitfire"]?.notes == "Kit: 1:48")
        #expect(projects["Someday"]?.notes == "Ideas only")
        #expect(projects["Again"]?.notes == "Kit: Revell")
        #expect(projects.values.allSatisfy { $0.kits.isEmpty })

        let kits = try context.fetch(FetchDescriptor<Kit>())
        #expect(kits.map(\.name) == ["Super Cobra"])
        #expect(kits.first?.project == nil)
    }

    @Test func aLibraryIsCopiedBeforeItsUpgraded() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")
        try makeSchemaThreeLibrary(at: storeURL)
        let models = CurrentSchema.models
        let version = CurrentSchema.versionIdentifier
        let copyURL = LibraryUpgradeCopy.copyURL(for: storeURL, version: version)
        #expect(copyURL.lastPathComponent == "Library Before 5.0.0.store")

        #expect(try LibraryUpgradeCopy.needsUpgrade(storeURL: storeURL, models: models))
        #expect(try LibraryUpgradeCopy.makeIfNeeded(storeURL: storeURL, models: models, version: version) == copyURL)
        // A second try keeps the first copy.
        #expect(try LibraryUpgradeCopy.makeIfNeeded(storeURL: storeURL, models: models, version: version) == copyURL)

        do {
            _ = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
            )
        }
        #expect(try LibraryUpgradeCopy.needsUpgrade(storeURL: storeURL, models: models) == false)
        #expect(try LibraryUpgradeCopy.makeIfNeeded(storeURL: storeURL, models: models, version: version) == nil)

        // The copy is the schema 3 library, untouched.
        let schema = Schema(versionedSchema: Old.self)
        let copy = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: copyURL)])
        let cobra = try #require(try copy.mainContext.fetch(FetchDescriptor<Old.Project>())
            .first { $0.name == "Cobra" })
        #expect(cobra.manufacturer == "Italeri")
        #expect(cobra.notes == "Wheel wells")
        let staging = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasPrefix(".BenchBook-UpgradeCopy") }
        #expect(staging.isEmpty)
    }

    @Test func noCopyForANewOrMissingLibrary() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")
        let models = CurrentSchema.models
        #expect(try LibraryUpgradeCopy.makeIfNeeded(storeURL: storeURL, models: models,
                                                    version: CurrentSchema.versionIdentifier) == nil)
        do {
            _ = try PersistenceController.makeContainer(
                configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
            )
        }
        #expect(try LibraryUpgradeCopy.makeIfNeeded(storeURL: storeURL, models: models,
                                                    version: CurrentSchema.versionIdentifier) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).allSatisfy { !$0.contains("Before") })
    }
}

@MainActor
struct ProjectKitModelTests {
    @Test func deletingAProjectKeepsItsKits() throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let project = Fixtures.makeProject("Cobra", in: context)
        let kit = Kit(brand: "Italeri", name: "Super Cobra", scale: "1:72")
        kit.status = .wip
        context.insert(kit)
        kit.project = project
        try context.save()
        #expect(project.kits == [kit])
        #expect(project.summary == "Italeri · 1:72")

        let library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        try ProjectService(context: context).delete(project, library: library)
        let kits = try context.fetch(FetchDescriptor<Kit>())
        #expect(kits.count == 1)
        #expect(kits.first?.project == nil)
        #expect(kits.first?.status == .wip)
    }

    @Test func addingMovingAndRemovingKits() throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let service = KitService(context: context, library: AssetLibrary(rootURL: folder.url))
        let cobra = Fixtures.makeProject("Cobra", in: context)
        let other = Fixtures.makeProject("Other", in: context)
        let old = Date(timeIntervalSince1970: 0)
        cobra.updatedAt = old
        other.updatedAt = old
        let kit = Kit(brand: "Italeri", name: "Super Cobra")
        let spare = Kit(brand: "Italeri", name: "Super Cobra")
        context.insert(kit)
        context.insert(spare)
        try context.save()
        #expect(Set(try service.unallocated()) == [kit, spare])

        try service.add([kit], to: cobra)
        #expect(cobra.kits == [kit])
        #expect(cobra.updatedAt > old)
        #expect(try service.unallocated() == [spare])

        // A kit is in one project at a time.
        cobra.updatedAt = old
        try service.add([kit], to: other)
        #expect(cobra.kits.isEmpty && other.kits == [kit])
        #expect(cobra.updatedAt > old)

        other.updatedAt = old
        try service.remove([kit], from: cobra)
        #expect(other.updatedAt == old)
        try service.remove([kit], from: other)
        #expect(kit.project == nil && other.updatedAt > old)
        #expect(try context.fetchCount(FetchDescriptor<Kit>()) == 2)
    }

    @Test func aNewKitCanGoStraightIntoANewProject() throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let project = Project(name: "Cobra")
        context.insert(project)
        var draft = KitDraft()
        draft.brand = "Italeri"
        draft.name = "Super Cobra"
        let kit = try KitService(context: context, library: AssetLibrary(rootURL: folder.url))
            .create(from: draft, in: project)
        #expect(kit.project == project)
        #expect(project.updatedAt == project.createdAt)
    }

    @Test(arguments: [
        (ProjectStatus.inProgress, "bnib", "wip"), (.inProgress, "opened", "wip"), (.inProgress, "wip", "wip"),
        (.inProgress, "built", "built"), (.inProgress, "painted", "painted"),
        (.completed, "bnib", "built"), (.completed, "wip", "built"), (.completed, "painted", "built"),
        (.researching, "bnib", "bnib"), (.paused, "opened", "opened"),
    ])
    func kitsMoveForwardWithTheProject(project: ProjectStatus, from: String, to: String) {
        let kit = Kit(brand: "Italeri", name: "Super Cobra", statusRaw: from)
        #expect(kit.follow(project) == (from != to))
        #expect(kit.statusRaw == to)
    }

    @Test func kitsNotOwnedKeepTheirStatus() {
        let kit = Kit(brand: "Italeri", name: "Super Cobra", isOwned: false)
        #expect(!kit.follow(.completed))
        #expect(kit.status == .bnib)
    }

    @Test func projectStatusChangesMoveItsKits() throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let projects = ProjectService(context: context)
        let kits = KitService(context: context, library: AssetLibrary(rootURL: folder.url))
        let project = Fixtures.makeProject("Cobra", in: context)
        let sealed = Kit(brand: "Italeri", name: "Super Cobra")
        let wanted = Kit(brand: "Italeri", name: "Super Cobra", isOwned: false)
        context.insert(sealed)
        context.insert(wanted)
        try kits.add([sealed, wanted], to: project)
        #expect(sealed.status == .bnib)

        try projects.setStatus(.inProgress, for: project)
        #expect(sealed.status == .wip)
        var draft = ProjectDraft(project: project)
        draft.status = .completed
        try projects.update(project, from: draft)
        #expect(sealed.status == .built)
        #expect(wanted.status == .bnib)
        // Moving the project back leaves its kits Built.
        try projects.setStatus(.inProgress, for: project)
        #expect(sealed.status == .built)

        // A kit added to a completed project is built.
        try projects.setStatus(.completed, for: project)
        let late = Kit(brand: "Italeri", name: "Super Cobra", statusRaw: "opened")
        context.insert(late)
        try kits.add([late], to: project)
        #expect(late.status == .built)
    }

    @Test func aNewProjectTakesItsChosenKits() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let old = Fixtures.makeProject("Old", in: context)
        old.updatedAt = Date(timeIntervalSince1970: 0)
        let moving = Kit(brand: "Italeri", name: "Super Cobra")
        let sealed = Kit(brand: "Revell", name: "Spitfire")
        for kit in [moving, sealed] { context.insert(kit) }
        moving.project = old
        try context.save()

        var draft = ProjectDraft()
        draft.name = "Cobra"
        draft.status = .inProgress
        let project = try ProjectService(context: context).createProject(from: draft, kits: [moving, sealed])
        #expect(Set(project.kits) == [moving, sealed])
        #expect(old.kits.isEmpty && old.updatedAt > Date(timeIntervalSince1970: 0))
        #expect(sealed.status == .wip)
        #expect(project.updatedAt == project.createdAt)
    }

    @Test func neededKitsAreNotOwnedAndForABuildNotYetCompleted() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let project = Fixtures.makeProject("Cobra", in: context)
        let wanted = Kit(brand: "Italeri", name: "Super Cobra", isOwned: false)
        let owned = Kit(brand: "Italeri", name: "Super Cobra")
        let spare = Kit(brand: "Revell", name: "Spitfire", isOwned: false)
        for kit in [wanted, owned, spare] { context.insert(kit) }
        wanted.project = project
        owned.project = project
        #expect(wanted.isNeeded && !owned.isNeeded && !spare.isNeeded)
        let kits = [wanted, owned, spare]
        #expect(kits.filter(KitFilter(ownership: .needed).includes) == [wanted])
        #expect(kits.filter(KitFilter(ownership: .unallocated).includes) == [spare])

        project.statusRaw = ProjectStatus.completed.rawValue
        #expect(!wanted.isNeeded)
    }

    @Test func deletingAKitNamesItsProject() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let project = Fixtures.makeProject("Cobra", in: context)
        let kit = Kit(brand: "Italeri", name: "Super Cobra")
        let spare = Kit(brand: "Revell", name: "Spitfire")
        for kit in [kit, spare] { context.insert(kit) }
        kit.project = project
        #expect(KitCatalogueView.deletionMessage([kit]).hasPrefix("It's used by the project “Cobra”."))
        #expect(!KitCatalogueView.deletionMessage([spare]).contains("used by"))
    }

    @Test func boughtKitsAreOwnedAndBNIB() throws {
        let folder = try TemporaryFolder()
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let kit = Kit(brand: "Italeri", name: "Super Cobra", isOwned: false, statusRaw: "wip")
        context.insert(kit)
        try KitService(context: context, library: AssetLibrary(rootURL: folder.url)).markBought([kit])
        #expect(kit.isOwned && kit.status == .bnib)
    }

    @Test func theShoppingListTextListsKitsFirst() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let kits = [PaintShoppingList.KitLine(title: "Italeri Super Cobra · 1:72 · 1234", project: "Cobra")]
        let text = PaintShoppingList(selections: []).text(on: date, kits: kits)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Shopping List")
        #expect(lines[1].hasSuffix(" · 1 kit"))
        #expect(Array(lines[2...5]) == ["", "Kits", "☐ Italeri Super Cobra · 1:72 · 1234", "    Cobra"])
        #expect(PaintShoppingList(selections: []).text(on: date).hasPrefix("Paint Shopping List\n"))
    }

    @Test func summaryCountsSeveralKits() throws {
        let container = try Fixtures.makeInMemoryContainer()
        let context = container.mainContext
        let project = Fixtures.makeProject("Diorama", in: context)
        project.subject = "Normandy"
        for name in ["Sherman", "Jeep"] {
            let kit = Kit(brand: "Tamiya", name: name, scale: "1:35")
            context.insert(kit)
            kit.project = project
        }
        #expect(project.summary == "2 kits · Normandy")
    }
}

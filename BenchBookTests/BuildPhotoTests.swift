import AppKit
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BenchBook

@MainActor
struct BuildPhotoTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    var service: BuildPhotoService { BuildPhotoService(context: context, library: library) }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    // MARK: Fixtures

    /// A JPEG with an EXIF date taken and, optionally, a GPS location.
    @discardableResult
    private func writePhoto(_ name: String, taken: String? = "2025:07:18 14:32:05", withLocation: Bool = false,
                            red: CGFloat = 0.5) throws -> URL {
        let url = folder.file(name)
        let pngURL = try Fixtures.writePNG(to: folder.file("\(name).png"), width: 120, height: 90, red: red)
        let source = try #require(CGImageSourceCreateWithURL(pngURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let taken {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken]
        }
        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 51.5,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12,
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func hasLocation(_ url: URL) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    private func add(_ urls: [URL], to project: Project) async throws -> [BuildPhoto] {
        let outcomes = await service.addPhotos(urls.map { (url: $0, filename: $0.lastPathComponent) }, to: project)
        return outcomes.compactMap { if case .added(let photo) = $0 { photo } else { nil } }
    }

    private func originals() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: library.originalsURL, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Adding

    @Test func addsPhotoAsByteIdenticalOriginalWithDateTaken() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try writePhoto("cockpit.jpg", withLocation: true)

        let photo = try #require(try await add([source], to: project).first)
        let asset = try #require(photo.asset)

        #expect(photo.stage == .wip)
        #expect(photo.notes == nil)
        #expect(photo.takenAt == ImageMetadata.parseExifDate("2025:07:18 14:32:05"))
        #expect(asset.originalFilename == "cockpit.jpg")
        #expect(try Data(contentsOf: library.url(forRelativePath: asset.originalRelativePath)) == Data(contentsOf: source))
        // The original keeps its location; only exports leave it out.
        #expect(try hasLocation(library.url(forRelativePath: asset.originalRelativePath)))
        #expect(project.buildPhotos.count == 1)
        #expect(project.references.isEmpty)
    }

    @Test func photoWithoutADateUsesWhenItWasAdded() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let before = Date.now.addingTimeInterval(-1)
        let photo = try #require(try await add([try writePhoto("undated.jpg", taken: nil)], to: project).first)
        #expect(photo.takenAt >= before)
        #expect(photo.takenAt <= .now)
    }

    @Test func rejectsDuplicatesAndFilesThatArentPhotos() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try writePhoto("one.jpg")
        let pdf = try Fixtures.writePDF(to: folder.file("instructions.pdf"))
        _ = try await add([photo], to: project)

        let outcomes = await service.addPhotos([(url: photo, filename: "one again.jpg"), (url: pdf, filename: "instructions.pdf")], to: project)

        guard case .duplicate(_, let name) = outcomes[0] else {
            Issue.record("Expected a duplicate, got \(outcomes[0])")
            return
        }
        #expect(name == "one again.jpg")
        guard case .failed(_, let error) = outcomes[1] else {
            Issue.record("Expected a failure, got \(outcomes[1])")
            return
        }
        #expect(error as? BuildPhotoError == .notAPhoto("instructions.pdf"))
        #expect(project.buildPhotos.count == 1)
        #expect(originals().count == 1)
    }

    @Test func samePhotoTwiceInOneDropIsAddedOnceWithoutAReport() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try writePhoto("drag.jpg")
        let copy = folder.file("45DE23D1.jpeg")
        try FileManager.default.copyItem(at: photo, to: copy)

        let outcomes = await service.addPhotos([(url: photo, filename: "drag.jpg"), (url: copy, filename: "45DE23D1.jpeg")], to: project)

        #expect(outcomes.count == 1)
        guard case .added = try #require(outcomes.first) else {
            Issue.record("Expected .added, got \(outcomes)")
            return
        }
        #expect(project.buildPhotos.count == 1)

        // A later drop of the same photo is still reported.
        let later = await service.addPhotos([(url: copy, filename: "45DE23D1.jpeg")], to: project)
        guard case .duplicate = try #require(later.first) else {
            Issue.record("Expected .duplicate, got \(later)")
            return
        }
    }

    @Test func samePhotoCanBeABuildPhotoAndAReference() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try writePhoto("shared.jpg")
        _ = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: source, originalFilename: "shared.jpg", resourceURL: nil)], into: project)
        let photos = try await add([source], to: project)
        #expect(photos.count == 1)
        #expect(project.references.count == 1)
    }

    // MARK: Details, stages and the project photo

    @Test func editsNotesDateStageAndTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg")], to: project).first)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        try service.update(photo, notes: "  Cockpit painted\nbefore washes  ", takenAt: date, stage: .completed,
                           tagsText: "Cockpit, weathering, cockpit")

        #expect(photo.notes == "Cockpit painted\nbefore washes")
        #expect(photo.caption == "Cockpit painted")
        #expect(photo.displayTitle == "Cockpit painted")
        #expect(photo.takenAt == date)
        #expect(photo.stage == .completed)
        #expect(photo.tags.map(\.name) == ["Cockpit", "weathering"])

        try service.update(photo, notes: "", takenAt: date, stage: .wip, tagsText: "weathering")
        #expect(photo.notes == nil)
        #expect(photo.displayTitle == date.formatted(date: .abbreviated, time: .shortened))
        #expect(photo.tags.map(\.name) == ["weathering"])
    }

    @Test func groupsCompletedFirstThenWorkInProgressByDay() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add((0..<4).map { try writePhoto("p\($0).jpg", red: CGFloat($0) / 4) }, to: project)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        photos[0].takenAt = day1
        photos[1].takenAt = day1.addingTimeInterval(3600)
        photos[2].takenAt = day1.addingTimeInterval(86_400 * 2)
        photos[3].takenAt = day1
        try service.setStage(.completed, on: [photos[3]])

        let groups = BuildPhotoGroup.groups(project.buildPhotos, calendar: calendar)

        #expect(groups.map(\.id) == ["completed", "2023-11-16", "2023-11-14"])
        #expect(groups[0].photos.map(\.id) == [photos[3].id])
        #expect(groups[1].photos.map(\.id) == [photos[2].id])
        // Newest first within a day.
        #expect(groups[2].photos.map(\.id) == [photos[1].id, photos[0].id])
        #expect(project.sortedBuildPhotos.map(\.id) == [photos[3], photos[2], photos[1], photos[0]].map(\.id))
    }

    @Test func projectPhotoIsClearedWhenItsPhotoIsDeleted() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add([try writePhoto("a.jpg"), try writePhoto("b.jpg", red: 0.9)], to: project)

        try service.setProjectPhoto(photos[0], for: project)
        #expect(project.projectPhoto?.id == photos[0].id)

        try service.delete([photos[1]])
        #expect(project.projectPhoto?.id == photos[0].id)

        try service.delete([photos[0]])
        #expect(project.projectPhotoID == nil)
        #expect(project.projectPhoto == nil)
    }

    // MARK: Deleting

    @Test func deletingRemovesTheFileUnlessAReferenceUsesIt() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let shared = try writePhoto("shared.jpg")
        _ = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: shared, originalFilename: "shared.jpg", resourceURL: nil)], into: project)
        let photos = try await add([shared, try writePhoto("own.jpg", red: 0.1)], to: project)
        #expect(originals().count == 3)

        try service.delete(photos)

        #expect(project.buildPhotos.isEmpty)
        // The reference's own copy stays; the build photos' copies go.
        #expect(originals().count == 1)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 1)
    }

    @Test func aDeletedPhotoCanBeAddedAgain() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let source = try writePhoto("again.jpg")
        let first = try #require(try await add([source], to: project).first)

        try service.delete([first])
        #expect(originals().isEmpty)

        let outcomes = await service.addPhotos([(url: source, filename: "again.jpg")], to: project)
        guard case .added = try #require(outcomes.first) else {
            Issue.record("Expected .added, got \(outcomes)")
            return
        }
        #expect(project.buildPhotos.count == 1)
        #expect(originals().count == 1)
    }

    @Test func deletingAPhotoDeletesItsNotesAndTagLinksButNotTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg")], to: project).first)
        try service.update(photo, notes: "", takenAt: photo.takenAt, stage: .wip, tagsText: "cockpit")
        try ImageNoteService(context: context)
            .addNote(to: .buildPhoto(photo), pixelRect: CGRect(x: 10, y: 10, width: 60, height: 50), imageSize: CGSize(width: 120, height: 90))
        #expect(photo.sortedImageNotes.count == 1)

        try service.delete([photo])

        #expect(try context.fetchCount(FetchDescriptor<Markup>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BuildPhotoTag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BenchBook.Tag>()) == 1)
    }

    @Test func deletingAProjectDeletesItsPhotosAndFiles() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        _ = try await add([try writePhoto("a.jpg"), try writePhoto("b.jpg", red: 0.9)], to: project)
        #expect(project.deletionSummary.contains("2 build photos"))

        try ProjectService(context: context).delete(project, library: library)

        #expect(try context.fetchCount(FetchDescriptor<BuildPhoto>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ManagedAsset>()) == 0)
        #expect(originals().isEmpty)
    }

    // MARK: Box notes and the viewer

    @Test func boxNotesBelongToThePhotoAndAreNumberedInOrder() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg")], to: project).first)
        let notes = ImageNoteService(context: context)
        let size = CGSize(width: 120, height: 90)
        let first = try #require(try notes.addNote(to: .buildPhoto(photo), pixelRect: CGRect(x: 0, y: 0, width: 60, height: 40), imageSize: size))
        let second = try #require(try notes.addNote(to: .buildPhoto(photo), pixelRect: CGRect(x: 60, y: 40, width: 60, height: 50), imageSize: size))

        #expect(photo.sortedImageNotes.map(\.id) == [first.id, second.id])
        #expect(first.buildPhoto?.id == photo.id)
        #expect(first.reference == nil)
        #expect(first.imageID == photo.id)
    }

    @Test func viewerFindsBuildPhotosAndReferenceImagesByID() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add([try writePhoto("a.jpg"), try writePhoto("b.jpg", red: 0.9)], to: project)
        let outcomes = await ReferenceImporter(context: context, library: library).importItems(
            [.file(url: try Fixtures.writePNG(to: folder.file("ref.png")), originalFilename: "ref.png", resourceURL: nil)],
            into: project
        )
        guard case .added(let reference) = try #require(outcomes.first) else { return }
        let note = Reference(project: project, kind: .note, text: "Not an image")
        context.insert(note)
        try context.save()

        let found = ViewerImage.find([photos[1].id, reference.id, note.id, UUID(), photos[0].id], in: context)

        #expect(found.map(\.id) == [photos[1].id, reference.id, photos[0].id])
        // Previous and next stay among build photos.
        #expect(Set(found[0].siblingIDs) == Set(photos.map(\.id)))
        #expect(found[1].siblingIDs == [reference.id])
    }

    // MARK: Tags

    @Test func tagUsageCountsBuildPhotos() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add([try writePhoto("a.jpg"), try writePhoto("b.jpg", red: 0.9)], to: project)
        let reference = Reference(project: project, kind: .note, text: "Wash colours")
        context.insert(reference)
        let tags = TagService(context: context)
        try tags.addTags(named: "weathering", to: [reference])
        let weathering = try #require(try tags.existingTag(named: "weathering"))
        try tags.add(weathering, to: photos)

        #expect(weathering.usageCount == 3)
        #expect(weathering.usageSummary == "1 reference, 2 build photos")
        #expect(weathering.projectNames == ["F-16"])
        #expect(tags.state(of: weathering, on: photos) == .all)

        try tags.toggle(weathering, on: photos)
        #expect(tags.state(of: weathering, on: photos) == .none)
        #expect(weathering.usageSummary == "1 reference")
    }

    @Test func removeUnusedKeepsTagsUsedOnlyByBuildPhotos() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg")], to: project).first)
        let tags = TagService(context: context)
        try tags.addTags(named: "progress", to: [photo])
        try tags.createTag(named: "unused")

        #expect(try tags.removeUnused() == 1)
        #expect(try tags.existingTag(named: "progress") != nil)
        #expect(try tags.existingTag(named: "unused") == nil)
    }

    @Test func mergingAndDeletingTagsCoverBuildPhotos() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add([try writePhoto("a.jpg"), try writePhoto("b.jpg", red: 0.9)], to: project)
        let tags = TagService(context: context)
        try tags.addTags(named: "wip shots", to: [photos[0]])
        try tags.addTags(named: "progress", to: [photos[0], photos[1]])
        let source = try #require(try tags.existingTag(named: "wip shots"))
        let target = try #require(try tags.existingTag(named: "progress"))

        try tags.merge([source], into: target)
        #expect(photos[0].tags.map(\.name) == ["progress"])
        #expect(target.buildPhotoLinks.count == 2)

        try tags.delete([target])
        #expect(photos.allSatisfy { $0.tags.isEmpty })
        #expect(try context.fetchCount(FetchDescriptor<BuildPhoto>()) == 2)
    }

    // MARK: Search

    @Test func searchFindsNotesBoxNotesAndTags() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg")], to: project).first)
        try service.update(photo, notes: "Cockpit painted\nTry a darker wash", takenAt: photo.takenAt, stage: .wip,
                           tagsText: "weathering")
        let note = try #require(try ImageNoteService(context: context)
            .addNote(to: .buildPhoto(photo), pixelRect: CGRect(x: 10, y: 10, width: 60, height: 50), imageSize: CGSize(width: 120, height: 90)))
        note.text = "Seat belts"
        try context.save()
        let index = SearchIndex(context: context)

        let byNote = index.search(SearchQuery(text: "darker"))
        #expect(byNote.buildPhotoCount == 1)
        #expect(byNote.referenceGroups.first?.photoHits.first?.matches.contains { $0.kind == .note } == true)

        let byBox = index.search(SearchQuery(text: "belts"))
        #expect(byBox.referenceGroups.first?.photoHits.first?.matches.contains { $0.kind == .imageNote(id: note.id, number: 1) } == true)

        let byTag = index.search(SearchQuery(text: "", tags: ["weathering"]))
        #expect(byTag.buildPhotoCount == 1)
        #expect(byTag.referenceCount == 0)

        #expect(index.search(SearchQuery(text: "missing")).buildPhotoCount == 0)
    }

    // MARK: Exporting

    @Test func exportRemovesLocationByDefaultAndNamesFilesByDateAndCaption() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photos = try await add([try writePhoto("a.jpg", withLocation: true),
                                    try writePhoto("b.jpg", withLocation: true, red: 0.9)], to: project)
        try service.update(photos[0], notes: "Cockpit: done / ready", takenAt: photos[0].takenAt, stage: .wip, tagsText: "")
        let out = folder.url.appending(path: "Export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let written = try service.export(photos, to: out, removingLocation: true)

        #expect(written.count == 2)
        #expect(Set(written.map(\.lastPathComponent)) == ["2025-07-18 Cockpit done ready.jpg", "2025-07-18.jpg"])
        for url in written {
            #expect(try !hasLocation(url))
            #expect(NSImage(contentsOf: url) != nil)
        }
        // The originals in the library keep their location.
        for photo in photos {
            #expect(try hasLocation(library.url(forRelativePath: try #require(photo.asset).originalRelativePath)))
        }
    }

    @Test func exportCanKeepLocationAndNeverOverwrites() async throws {
        let project = Fixtures.makeProject("F-16", in: context)
        let photo = try #require(try await add([try writePhoto("a.jpg", withLocation: true)], to: project).first)
        let out = folder.url.appending(path: "Export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let first = try service.export([photo], to: out, removingLocation: false)
        let second = try service.export([photo], to: out, removingLocation: false)

        #expect(first.map(\.lastPathComponent) == ["2025-07-18.jpg"])
        #expect(second.map(\.lastPathComponent) == ["2025-07-18 2.jpg"])
        #expect(try hasLocation(first[0]))
        #expect(try Data(contentsOf: first[0]) == Data(contentsOf: library.url(forRelativePath: try #require(photo.asset).originalRelativePath)))
    }
}

/// Libraries saved by BenchBook 1.0 (schema 1) open with schema 2 and keep everything.
@MainActor
struct BuildPhotoMigrationTests {
    @Test func schemaOneLibraryOpensWithBuildPhotos() throws {
        let folder = try TemporaryFolder()
        let storeURL = folder.file("Library.store")

        do {
            let old = try ModelContainer(
                for: Schema(versionedSchema: BenchBookSchemaV1.self),
                configurations: [ModelConfiguration(schema: Schema(versionedSchema: BenchBookSchemaV1.self), url: storeURL)]
            )
            let context = old.mainContext
            let project = BenchBookSchemaV1.Project(name: "Spitfire", manufacturer: "Airfix", scale: "1:48")
            context.insert(project)
            let reference = BenchBookSchemaV1.Reference(project: project, kind: .note, text: "Cockpit green")
            context.insert(reference)
            let tag = BenchBookSchemaV1.Tag(name: "Cockpit", normalizedName: "cockpit")
            context.insert(tag)
            context.insert(BenchBookSchemaV1.ReferenceTag(reference: reference, tag: tag))
            try context.save()
        }

        let container = try PersistenceController.makeContainer(
            configuration: ModelConfiguration(schema: PersistenceController.schema, url: storeURL)
        )
        let context = container.mainContext
        let project = try #require(try context.fetch(FetchDescriptor<Project>()).first)
        #expect(project.name == "Spitfire")
        #expect(project.notes == "Kit: Airfix · 1:48")
        #expect(project.references.first?.text == "Cockpit green")
        #expect(project.references.first?.tags.map(\.name) == ["Cockpit"])
        #expect(project.buildPhotos.isEmpty)
        #expect(project.projectPhotoID == nil)

        let tag = try #require(try context.fetch(FetchDescriptor<BenchBook.Tag>()).first)
        #expect(tag.usageCount == 1)
        #expect(tag.buildPhotoLinks.isEmpty)
    }
}

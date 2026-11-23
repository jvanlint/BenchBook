import Foundation
import SwiftData
import Testing
@testable import BenchBook

struct ZipArchiveTests {
    private static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "spec/fixtures")

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func writesWhatItReads() throws {
        let folder = try TemporaryFolder()
        let source = try Fixtures.writeText(String(repeating: "BenchBook ", count: 5000), to: folder.file("big.txt"))
        let zip = folder.file("test.zip")
        let writer = try ZipArchive.Writer(creating: zip)
        try writer.add("manifest.json", data: Data("{}".utf8))
        try writer.add("Library/Originals/big.txt", contentsOf: source)
        try writer.add("empty.txt", data: Data())
        try writer.finish()
        #expect(ZipArchive.looksLikeZip(zip))

        let reader = try ZipArchive.Reader(zip)
        #expect(reader.entries.map(\.name) == ["manifest.json", "Library/Originals/big.txt", "empty.txt"])
        #expect(reader.entries.allSatisfy { $0.method == 0 })
        let out = folder.file("out")
        try reader.extractAll(to: out)
        #expect(try Data(contentsOf: out.appending(path: "Library/Originals/big.txt")) == Data(contentsOf: source))
        #expect(try Data(contentsOf: out.appending(path: "empty.txt")).isEmpty)
    }

    /// Made with Python's zipfile, as another tool (or Windows) might zip it.
    @Test func readsDeflatedEntries() throws {
        let folder = try TemporaryFolder()
        let reader = try ZipArchive.Reader(Self.fixtures.appending(path: "zip-deflated.zip"))
        #expect(reader.entries.contains { $0.method == 8 })
        try reader.extractAll(to: folder.url)
        let text = try String(contentsOf: folder.url.appending(path: "notes/readme.txt"), encoding: .utf8)
        #expect(text == String(repeating: "Made-up text for BenchBook's ZIP reader test.\n", count: 40))
    }

    @Test func refusesUnsafeNames() throws {
        #expect(throws: ZipArchive.ZipError.unsafeName("../outside.txt")) {
            try ZipArchive.Reader(Self.fixtures.appending(path: "zip-unsafe.zip"))
        }
        for name in ["/etc/x", "a/../b", "C:/x", "a\\b", "", "a//b", "./a"] {
            #expect(!ZipArchive.isSafeName(name), "\(name)")
        }
        #expect(ZipArchive.isSafeName("Library/Originals/0F8C.jpg"))
    }

    @Test func refusesFilesThatArentZips() throws {
        let folder = try TemporaryFolder()
        let text = try Fixtures.writeText("not a zip", to: folder.file("x.zip"))
        #expect(!ZipArchive.looksLikeZip(text))
        #expect(throws: ZipArchive.ZipError.notAZip) { try ZipArchive.Reader(text) }
    }
}

@MainActor
struct ProjectTransferTests {
    let folder: TemporaryFolder
    let library: AssetLibrary
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        folder = try TemporaryFolder()
        library = AssetLibrary(rootURL: folder.url.appending(path: "Library", directoryHint: .isDirectory))
        container = try Fixtures.makeInMemoryContainer()
    }

    /// Another library, as on another Mac or on Windows.
    private func otherLibrary() throws -> (ModelContainer, AssetLibrary) {
        let root = folder.url.appending(path: "Other-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (try Fixtures.makeInMemoryContainer(), AssetLibrary(rootURL: root))
    }

    /// One of every kind of record a project can have.
    private func makeProject() async throws -> Project {
        let project = Fixtures.makeProject("F-16C Viper", in: context)
        project.subject = "F-16C Block 50"
        project.notes = "Weathered, 2010s"
        project.statusRaw = ProjectStatus.inProgress.rawValue

        let image = try Fixtures.writePNG(to: folder.file("cockpit.png"))
        _ = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: image, originalFilename: "cockpit.png", resourceURL: nil)], into: project, tags: ["Cockpit"])
        let imageReference = try #require(project.references.first)
        context.insert(Markup(reference: imageReference, pageIndex: 0, kindRaw: "note", colorName: "yellow",
                              x: 0.1, y: 0.2, width: 0.3, height: 0.1, text: "Ejection seat"))

        let note = Reference(project: project, kind: .note, title: "Plan", text: "Prime, then pre-shade.")
        context.insert(note)
        let video = Reference(project: project, kind: .videoLink, title: "Weathering",
                              sourcePageURL: URL(string: "https://www.youtube.com/watch?v=abc")!)
        video.videoDurationSeconds = 612
        context.insert(video)
        context.insert(VideoMoment(reference: video, offsetSeconds: 95, title: "Oil dots"))
        try FileManager.default.createDirectory(at: library.postersURL, withIntermediateDirectories: true)
        try Fixtures.writeJPEG(to: library.posterURL(referenceID: video.id))

        let photoFile = try Fixtures.writeJPEG(to: folder.file("wip.jpg"))
        _ = await BuildPhotoService(context: context, library: library).addPhotos([(url: photoFile, filename: "wip.jpg")], to: project)
        let photo = try #require(project.buildPhotos.first)
        project.projectPhotoID = photo.id
        let tag = try #require(try context.fetch(FetchDescriptor<BenchBook.Tag>()).first)
        context.insert(BuildPhotoTag(photo: photo, tag: tag))
        context.insert(Markup(buildPhoto: photo, pageIndex: 0, kindRaw: "note", colorName: "red",
                              x: 0.5, y: 0.5, width: 0.2, height: 0.1, text: "Fix seam"))

        let paints = PaintService(context: context)
        var draft = PaintDraft()
        draft.brand = "Tamiya"
        draft.range = "Acrylic XF"
        draft.code = "XF-1"
        draft.name = "Flat Black"
        draft.isOwned = true
        let black = try paints.createPaint(from: draft)
        draft.code = "XF-2"
        draft.name = "Flat White"
        draft.isOwned = false
        let white = try paints.createPaint(from: draft)
        var mix = PaintDraft()
        mix.isMix = true
        mix.brand = "Custom"
        mix.name = "Light Grey"
        mix.recipe = [MixPartDraft(paintID: white.id, parts: 3), MixPartDraft(paintID: black.id, parts: 1)]
        let grey = try paints.createPaint(from: mix)
        try paints.add([grey, white], to: project)
        try paints.addColour(.fs("36270"), usedFor: "Upper surfaces", to: project)

        let item = AftermarketItem(project: project, productName: "Ejection seat", manufacturer: "Quinta",
                                   typeRaw: "resin", statusRaw: "inStash")
        item.productURL = URL(string: "https://example.com/seat")
        context.insert(item)

        let kit = Kit(brand: "Tamiya", name: "F-16C Block 50", scale: "1:48", number: "61098")
        kit.pricePaid = Decimal(string: "64.50")
        kit.project = project
        context.insert(kit)
        try context.save()
        let box = try Fixtures.writePNG(to: folder.file("box.png"), width: 12, height: 9)
        try await KitService(context: context, library: library).setPicture(from: box, on: kit)
        return project
    }

    private func export(_ project: Project, personal: Bool = true) throws -> URL {
        let package = try ProjectExporter(library: library)
            .package(project, includePersonalDetails: personal, appVersion: "1.3.0", schemaVersion: "6.0.0")
        let url = folder.file("\(UUID().uuidString).benchbookproject")
        try ProjectExporter.write(package, to: url)
        return url
    }

    private func open(_ url: URL) throws -> ProjectFile {
        try ProjectFile.open(url, staging: folder.url.appending(path: "Staging", directoryHint: .isDirectory))
    }

    private func records(_ project: Project, in library: AssetLibrary) throws -> LibraryRecords {
        try ProjectExporter(library: library)
            .package(project, includePersonalDetails: true, appVersion: "1.3.0", schemaVersion: "6.0.0").records
    }

    private func originals(_ library: AssetLibrary) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.originalsURL.path)) ?? []).sorted()
    }

    @Test func roundTripsIntoAnotherLibrary() async throws {
        let project = try await makeProject()
        let file = try open(try export(project))
        defer { file.discard() }
        #expect(file.manifest.kind == "project" && file.manifest.platform == "mac" && file.manifest.includesPersonalDetails)
        #expect(file.manifest.counts == .init(references: 3, buildPhotos: 1, paints: 3, aftermarketItems: 1, kits: 1))

        let (otherContainer, otherLibrary) = try otherLibrary()
        let importer = ProjectImporter(context: otherContainer.mainContext, library: otherLibrary)
        #expect(try importer.existingProject(for: file) == nil)
        let summary = try importer.importProject(file, mode: .add)
        #expect(summary.projectName == "F-16C Viper" && summary.projectID == project.id)
        #expect(summary.paintsAdded == 3 && summary.tagsAdded == 1 && summary.kitsAdded == 1)

        let imported = try #require(try otherContainer.mainContext.fetch(FetchDescriptor<Project>()).first)
        // The same records, ids, dates and files.
        // As the file stores them: dates to the millisecond.
        let encoder = LibraryRecords.encoder()
        #expect(try encoder.encode(records(imported, in: otherLibrary)) == encoder.encode(records(project, in: library)))
        #expect(originals(otherLibrary) == originals(library))
        let video = try #require(project.references.first { $0.kind == .videoLink })
        #expect(FileManager.default.fileExists(atPath: otherLibrary.posterURL(referenceID: video.id).path))
        let black = try #require(try otherContainer.mainContext.fetch(FetchDescriptor<Paint>()).first { $0.code == "XF-1" })
        #expect(black.isOwned)
        #expect(imported.kits.first?.pricePaid == Decimal(string: "64.50"))
        #expect(imported.kits.first?.picture != nil)
    }

    @Test func leavesOutPricesAndOwnershipUnlessAsked() async throws {
        let project = try await makeProject()
        let file = try open(try export(project, personal: false))
        defer { file.discard() }
        #expect(!file.manifest.includesPersonalDetails)
        #expect(file.records.ownedPaints.isEmpty)
        #expect(file.records.kits.first?.pricePaid == nil)

        let (otherContainer, otherLibrary) = try otherLibrary()
        _ = try ProjectImporter(context: otherContainer.mainContext, library: otherLibrary).importProject(file, mode: .add)
        let paints = try otherContainer.mainContext.fetch(FetchDescriptor<Paint>())
        #expect(paints.count == 3 && paints.allSatisfy { !$0.isOwned })
    }

    @Test func usesCatalogueTagsAndPaintsWithoutChangingThem() async throws {
        let project = try await makeProject()
        let file = try open(try export(project))
        defer { file.discard() }

        let (otherContainer, otherLibrary) = try otherLibrary()
        let other = otherContainer.mainContext
        var draft = PaintDraft()
        draft.brand = "tamiya"
        draft.range = "acrylic xf"
        draft.code = "XF 2"
        draft.name = "My White"
        let mine = try PaintService(context: other).createPaint(from: draft)
        let tag = try TagService(context: other).createTag(named: "cockpit")

        let summary = try ProjectImporter(context: other, library: otherLibrary).importProject(file, mode: .add)
        #expect(summary.paintsMatched == 1 && summary.paintsAdded == 2 && summary.tagsAdded == 0)
        #expect(mine.name == "My White")
        #expect(mine.projectSelections.count == 1)
        #expect(try other.fetch(FetchDescriptor<BenchBook.Tag>()) == [tag])
        #expect(tag.referenceLinks.count == 1 && tag.buildPhotoLinks.count == 1)
    }

    @Test func keepBothAddsACopySharingFiles() async throws {
        let project = try await makeProject()
        let file = try open(try export(project))
        defer { file.discard() }
        let importer = ProjectImporter(context: context, library: library)
        #expect(try importer.existingProject(for: file) === project)
        let files = originals(library)

        let summary = try importer.importProject(file, mode: .keepBoth)
        #expect(summary.projectName == "F-16C Viper Copy" && summary.projectID != project.id)
        #expect(summary.paintsAdded == 0 && summary.paintsMatched == 3 && summary.tagsAdded == 0)
        // A kit is one box: it stays with the original project.
        #expect(summary.kitsInOtherProjects.count == 1 && summary.kitsMatched == 0)

        let projects = try context.fetch(FetchDescriptor<Project>())
        #expect(projects.count == 2)
        let copy = try #require(projects.first { $0.id == summary.projectID })
        #expect(copy.references.count == 3 && copy.buildPhotos.count == 1 && copy.paintRequirements.count == 3)
        #expect(Set(copy.references.map(\.id)).isDisjoint(with: project.references.map(\.id)))
        #expect(copy.projectPhotoID == copy.buildPhotos.first?.id)
        #expect(copy.kits.isEmpty && project.kits.count == 1)
        #expect(originals(library) == files)
        #expect(try context.fetch(FetchDescriptor<Paint>()).count == 3)
        let video = try #require(copy.references.first { $0.kind == .videoLink })
        #expect(FileManager.default.fileExists(atPath: library.posterURL(referenceID: video.id).path))
        #expect(video.videoMoments.count == 1)
    }

    @Test func replacePutsTheProjectBackAsExported() async throws {
        let project = try await makeProject()
        let projectID = project.id
        let file = try open(try export(project))
        defer { file.discard() }

        // Changes after the export: a rename, a deleted note and a new image.
        project.name = "Renamed"
        let note = try #require(project.references.first { $0.kind == .note })
        context.delete(note)
        let extra = try Fixtures.writePNG(to: folder.file("extra.png"), width: 5, height: 5, red: 0.2)
        _ = await ReferenceImporter(context: context, library: library)
            .importItems([.file(url: extra, originalFilename: "extra.png", resourceURL: nil)], into: project)
        try context.save()
        #expect(originals(library).count == 4)

        let importer = ProjectImporter(context: context, library: library)
        let existing = try #require(try importer.existingProject(for: file))
        let summary = try importer.importProject(file, mode: .replace)
        #expect(summary.projectID == projectID && summary.kitsMatched == 1)

        let projects = try context.fetch(FetchDescriptor<Project>())
        #expect(projects.count == 1)
        let restored = try #require(projects.first)
        #expect(restored !== existing)
        #expect(restored.name == "F-16C Viper")
        #expect(restored.references.map(\.kindRaw).sorted() == ["image", "note", "videoLink"])
        #expect(restored.kits.count == 1)
        // The extra image's file went with the project it was in.
        #expect(originals(library).count == 3)
        #expect(try context.fetch(FetchDescriptor<Reference>()).count == 3)
        #expect(try context.fetch(FetchDescriptor<Kit>()).count == 1)
    }

    @Test func refusesDamagedAndForeignFiles() async throws {
        let project = try await makeProject()
        let url = try export(project)

        // Change one byte of the last stored file.
        var bytes = try Data(contentsOf: url)
        let reader = try ZipArchive.Reader(url)
        let entry = try #require(reader.entries.last { $0.uncompressedSize > 0 && $0.name.hasPrefix("Library/") })
        let header = Int(entry.localHeaderOffset)
        let nameLength = Int(bytes[header + 26]) | Int(bytes[header + 27]) << 8
        let extraLength = Int(bytes[header + 28]) | Int(bytes[header + 29]) << 8
        bytes[header + 30 + nameLength + extraLength] ^= 0xFF
        let damaged = folder.file("damaged.benchbookproject")
        try bytes.write(to: damaged)
        #expect(throws: ProjectFileError.damaged(entry.name)) { try open(damaged) }

        // A file the manifest doesn't list.
        let extra = folder.file("extra.benchbookproject")
        let writer = try ZipArchive.Writer(creating: extra)
        let unpacked = folder.file("unpacked")
        try ZipArchive.Reader(url).extractAll(to: unpacked)
        for item in reader.entries { try writer.add(item.name, contentsOf: unpacked.appending(path: item.name)) }
        try writer.add("Library/Originals/stray.txt", data: Data("x".utf8))
        try writer.finish()
        #expect(throws: ProjectFileError.notAProjectFile) { try open(extra) }

        // A newer format.
        let newer = folder.file("newer.benchbookproject")
        let newerWriter = try ZipArchive.Writer(creating: newer)
        try newerWriter.add("manifest.json", data: Data(#"{"format": 3, "kind": "project"}"#.utf8))
        try newerWriter.finish()
        #expect(throws: ProjectFileError.newerFormat) { try open(newer) }

        // Not a ZIP at all, and a backup rather than a project.
        let text = try Fixtures.writeText("hello", to: folder.file("text.benchbookproject"))
        #expect(throws: ProjectFileError.notAProjectFile) { try open(text) }
        let backup = folder.file("backup.benchbookproject")
        let backupWriter = try ZipArchive.Writer(creating: backup)
        try backupWriter.add("manifest.json", data: Data(#"{"format": 2}"#.utf8))
        try backupWriter.finish()
        #expect(throws: ProjectFileError.notAProjectFile) { try open(backup) }
        #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
    }

    @Test func writesTheFormatsValueTypes() async throws {
        let project = try await makeProject()
        let file = try open(try export(project))
        defer { file.discard() }
        let json = try String(contentsOf: file.folder.appending(path: "library.json"), encoding: .utf8)
        #expect(json.contains(#""pricePaid" : "64.5""#) || json.contains(#""pricePaid" : "64.50""#))
        #expect(json.contains(project.id.uuidString))
        #expect(json.range(of: #""createdAt" : "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z""#, options: .regularExpression) != nil)
        #expect(!json.contains(#""notes" : """#) && !json.contains(#""title" : """#), "Empty optional text is left out")
    }

    @Test func suggestsAFileNameWindowsAccepts() {
        let project = Project(name: "F-16C: \"Viper\" 1/48?")
        #expect(ProjectExporter.suggestedFilename(for: project) == "F-16C- -Viper- 1-48-")
    }
}

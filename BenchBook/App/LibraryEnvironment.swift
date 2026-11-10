import SwiftData
import SwiftUI

/// Everything the window needs to work with one open library.
final class LibraryEnvironment {
    let container: ModelContainer
    let assetLibrary: AssetLibrary
    let thumbnails: ThumbnailStore
    let capture: CaptureCoordinator
    let linkInfo: LinkInfoService
    let imageSuggestions: ImageSuggestionService
    let search: SearchIndex
    /// Nil for tests and debug stores, which don't take part in sharing.
    let projectDirectory: ProjectDirectory?
    /// Nil for tests, whose store is in memory.
    let location: LibraryLocation?
    let restoreNotice: RestoreNotice

    init() throws {
        // A restore confirmed before relaunch replaces the library before it opens.
        location = PersistenceController.location
        restoreNotice = RestoreNotice(location.flatMap { LibraryRestore.finishPending(for: $0) })
        container = try PersistenceController.makeContainer()
        assetLibrary = PersistenceController.makeAssetLibrary()
        thumbnails = ThumbnailStore(library: assetLibrary)

        let sharesWithExtension = PersistenceController.usesDefaultLibrary
        let inbox = sharesWithExtension ? AppGroup.inboxURL.map(CaptureInboxStore.init) : nil
        projectDirectory = sharesWithExtension ? AppGroup.defaults.map(ProjectDirectory.init) : nil
        capture = CaptureCoordinator(context: container.mainContext, library: assetLibrary, inbox: inbox)
        linkInfo = LinkInfoService(context: container.mainContext, library: assetLibrary)
        capture.linkInfo = linkInfo
        imageSuggestions = ImageSuggestionService(context: container.mainContext, library: assetLibrary)
        capture.imageSuggestions = imageSuggestions
        search = SearchIndex(context: container.mainContext)

        _ = try? ReferenceService(context: container.mainContext, library: assetLibrary).reconcileLibrary()
        // Links saved while offline, or before their details were fetched.
        linkInfo.fetchMissing()
    }
}

extension EnvironmentValues {
    @Entry var assetLibrary = AssetLibrary(rootURL: FileManager.default.temporaryDirectory)
    @Entry var thumbnailStore: ThumbnailStore?
    @Entry var captureCoordinator: CaptureCoordinator?
    @Entry var linkInfoService: LinkInfoService?
    @Entry var imageSuggestionService: ImageSuggestionService?
    @Entry var searchIndex: SearchIndex?
    @Entry var projectDirectory: ProjectDirectory?
    @Entry var libraryLocation: LibraryLocation?
    @Entry var restoreNotice: RestoreNotice?
}

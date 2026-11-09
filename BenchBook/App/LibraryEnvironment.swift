import SwiftData
import SwiftUI

/// Everything the window needs to work with one open library.
final class LibraryEnvironment {
    let container: ModelContainer
    let assetLibrary: AssetLibrary
    let thumbnails: ThumbnailStore
    let capture: CaptureCoordinator
    let linkInfo: LinkInfoService
    let search: SearchIndex
    /// Nil for tests and debug stores, which don't take part in sharing.
    let projectDirectory: ProjectDirectory?

    init() throws {
        container = try PersistenceController.makeContainer()
        assetLibrary = PersistenceController.makeAssetLibrary()
        thumbnails = ThumbnailStore(library: assetLibrary)

        let sharesWithExtension = PersistenceController.usesDefaultLibrary
        let inbox = sharesWithExtension ? AppGroup.inboxURL.map(CaptureInboxStore.init) : nil
        projectDirectory = sharesWithExtension ? AppGroup.defaults.map(ProjectDirectory.init) : nil
        capture = CaptureCoordinator(context: container.mainContext, library: assetLibrary, inbox: inbox)
        linkInfo = LinkInfoService(context: container.mainContext, library: assetLibrary)
        capture.linkInfo = linkInfo
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
    @Entry var searchIndex: SearchIndex?
    @Entry var projectDirectory: ProjectDirectory?
}

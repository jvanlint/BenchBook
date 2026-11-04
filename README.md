# BenchBook

A native macOS app for gathering and using scale-modelling research, organised by build Project. The product references are in [`docs/`](docs/): requirements, data model, macOS architecture and implementation plan.

## Current scope

Phases 0–1 of [`docs/implementation-plan.md`](docs/implementation-plan.md), plus the interim capture work described at the end of that file:

- Project sidebar, a create/edit sheet (name required), and a References / Paint / Aftermarket workspace.
- References: images (JPEG, PNG, WebP, HEIC), PDFs, Markdown files, webpage links, video links (YouTube timestamps become moments) and highlighted text snippets.
- Capture by dragging onto the window or a sidebar project, pasting (⌘V), Add Files (⌘O), or the macOS Share menu (**BenchBook**), with optional tags and a note.
- A gallery of tiles (preview, title, type, tags) with type and tag filters. Images open in a viewer window; other files open in Quick Look (Space previews anything); links open in the browser.
- Image notes: zoom and pan a photo, draw boxes around features, and attach a numbered note to each. The original image is never changed.
- Local SwiftData persistence, with originals copied byte-for-byte into an app-managed file library.

Deferred: Project status, cover and deletion; search; paint; aftermarket; Safari/Chromium extensions; and sync.

## Requirements

| | |
|---|---|
| Deployment target | **macOS 15.0** |
| Built with | Xcode 27, Swift 5 language mode, default MainActor isolation |
| Dependencies | None |

Why macOS 15: everything used now (SwiftData, `VersionedSchema`, `ContentUnavailableView`, `NavigationSplitView`, `@Entry`) also runs on macOS 14. macOS 15 adds SwiftData's `#Index` and `#Unique` macros, which the data-model guide expects to evaluate for reference queries and identity rules, and includes SwiftData fixes released after its first version. Lowering the target to 14.0 later is possible, as long as those macros aren't adopted.

## Layout

```text
BenchBook/
  App/        App entry point, menu commands, LibraryEnvironment (shared services)
  Models/     Versioned SwiftData schemas (V1, V2), migration plan, display helpers
  Services/   Store setup, Project/Reference services, import, file checks,
              asset library, thumbnails, Share inbox
  Views/      Sidebar, workspace, references gallery, editors,
              ImageViewer/ (viewer window, zoomable canvas, notes panel)
Shared/       Code compiled into both the app and the Share extension
BenchBookShare/  The Share extension (share sheet UI)
BenchBookTests/  Swift Testing unit tests
```

Rules:

- Views edit a `ProjectDraft` and hand it to `ProjectService`. The service validates the draft, normalises blank optional text to `nil`, updates `updatedAt` and saves explicitly.
- Every capture path goes through `ReferenceImporter`. It checks file contents (not names), copies the original byte-for-byte into the asset library, then saves the Reference. Within a Project, an identical file is reported as already saved instead of being added twice.
- The Share extension never writes to the library. It leaves an envelope (files plus JSON) in the App Group inbox, and `CaptureCoordinator` imports it when BenchBook is running. The extension starts BenchBook in the background after sending. The App Group also holds the Project list and the active Project shown in the share sheet.
- Schemas are versioned (`BenchBookSchemaV1` to `BenchBookSchemaV3`, `BenchBookMigrationPlan`). Add a new schema and stage for each model change; never edit one that has shipped.
- If the store fails to open, the app shows an error and leaves the store alone. It never deletes or resets it.

Storage, inside `~/Library/Containers/com.jasonvanlint.BenchBook/Data/Library/Application Support/`:

- `BenchBook.store`: the SwiftData store.
- `Library/Originals/<asset-id>.<ext>`: saved files.
- `Library/Thumbnails/<asset-id>.png`: generated previews, safe to delete.

The App Group (`952LYY5FW2.com.jasonvanlint.BenchBook`) holds the share inbox and the shared Project list.

## Using the Share menu

1. Run BenchBook once from Xcode so macOS registers the extension.
2. If BenchBook doesn't appear in a Share menu, turn it on in System Settings → General → Login Items & Extensions → Sharing.
3. In Safari, use File → Share or the toolbar Share button for a page, or select text and Control-click → Share. In Chrome, use File → Share. In Finder, select files and Share.

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘N | New Project |
| ⌘O | Add files to the selected Project |
| ⌘V | Paste images, files, links or text into the selected Project |
| Return | Open the selected reference |
| Space | Quick Look the selected reference |
| ⌫ | Delete the selected reference (asks first) |
| ⌘I | Edit selected Project |
| ⌘1 / ⌘2 / ⌘3 | References / Paint / Aftermarket |
| ⌃⌘S | Show or hide sidebar |

In the image viewer:

| Shortcut | Action |
|---|---|
| ⌘D | Draw Box (Esc cancels) |
| ⌘B | Show or hide boxes |
| ⌫ | Delete the selected box (asks first) |
| ⌘= / ⌘− | Zoom in / out (or pinch, a mouse scroll wheel, or ⌘-scroll) |
| ⌘9 / ⌘0 | Zoom to Fit (or middle-click) / Actual Size |
| ⌘[ / ⌘] | Previous / next image |
| ⌥⌘I | Show or hide the Notes and Info panel |

## Testing

```sh
xcodebuild -project BenchBook.xcodeproj -scheme BenchBook -destination 'platform=macOS' test
```

To try the app without touching your real library, launch a Debug build with a separate store. This also keeps it out of Share-extension handoff:

```sh
open BenchBook.app --args -BenchBookStoreName BenchBookScratch
```

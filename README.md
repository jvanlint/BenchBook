# BenchBook

A native macOS app for gathering and using scale-modelling research, organised by build Project.

## Current scope

What BenchBook does so far:

- Project sidebar, a create/edit sheet (name required), and a References / Paint / Aftermarket workspace.
- References: images (JPEG, PNG, WebP, HEIC), PDFs, Markdown files, webpage links (with the page's preview image, site name and description), video links (YouTube timestamps become moments; YouTube and Vimeo links get their poster, title, channel, length, publish date and description), highlighted text snippets, and notes you write yourself (New Note, ⇧⌘N).
- Capture by dragging onto the window or a sidebar project, pasting (⌘V), Add Files (⌘O), or the macOS Share menu (**BenchBook**), with optional tags and a note.
- A gallery of tiles (preview, title, type, tags) with type and tag filters. Images open in a viewer window; other files open in Quick Look (Space previews anything); links open in the browser.
- Paints: a library-wide catalogue (add, edit, owned, CSV import) and a per-project paint list with what each paint is used for and what still needs buying.
- Aftermarket: each project's decals, resin, photo-etch and other parts, with type, status, scale or fit, product page, picture and notes.
- Image notes: zoom and pan a photo, draw boxes around features, and attach a numbered note to each. The original image is never changed.
- Local SwiftData persistence, with originals copied byte-for-byte into an app-managed file library.

Deferred: Project status, cover and deletion; paint colour standards and matches; Safari/Chromium extensions; and sync.

## Requirements

| | |
|---|---|
| Deployment target | **macOS 15.0** |
| Built with | Xcode 27, Swift 5 language mode, default MainActor isolation |
| Dependencies | None |

Why macOS 15: everything used now (SwiftData, `VersionedSchema`, `ContentUnavailableView`, `NavigationSplitView`, `@Entry`) also runs on macOS 14. macOS 15 adds SwiftData's `#Index` and `#Unique` macros, which may be useful for reference queries and identity rules, and includes SwiftData fixes released after its first version. Lowering the target to 14.0 later is possible, as long as those macros aren't adopted.

## Layout

```text
BenchBook/
  App/        App entry point, menu commands, LibraryEnvironment (shared services)
  Models/     Versioned SwiftData schemas (V1–V9), migration plan, display helpers
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
- Schemas are versioned (`BenchBookSchemaV1` to `BenchBookSchemaV9`, `BenchBookMigrationPlan`). Add a new schema and stage for each model change; never edit one that has shipped.
- If the store fails to open, the app shows an error and leaves the store alone. It never deletes or resets it.

Storage, inside `~/Library/Containers/com.jasonvanlint.BenchBook/Data/Library/Application Support/`:

- `BenchBook.store`: the SwiftData store.
- `Library/Originals/<asset-id>.<ext>`: saved files.
- `Library/Thumbnails/<asset-id>.png`: generated previews, safe to delete.
- `Library/Posters/<reference-id>.jpg`: video posters and webpage previews, safe to delete (Refresh Video Details or Refresh Page Preview fetches them again).

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

## Importing paints

Paints → Import CSV… reads a CSV file whose first row names the columns. Brand and Code are required; Range, Name, FS/RLM, Colour (`#RRGGBB`), Owned (`yes`, `x`, `1`…) and Notes are optional. Colour standards can be one `FS/RLM` column, or separate `FS`, `RLM`, `BS`, `RAL` or `ANA` columns; a bare number there gets its prefix (`36270` in an `FS` column becomes `FS 36270`). Paints already in the catalogue are skipped.

```csv
Brand,Range,Code,Name,FS/RLM,Colour,Owned
Tamiya,Acrylic XF,XF-54,Dark Sea Grey,BS 640,#5B6066,yes
Mr. Color,Lacquer,C307,Gray,FS 36320,#6E7377,
Gunze,Aqueous,H-417,RLM76 Light Blue,RLM 76,,
```

## Testing

```sh
xcodebuild -project BenchBook.xcodeproj -scheme BenchBook -destination 'platform=macOS' test
```

To try the app without touching your real library, launch a Debug build with a separate store. This also keeps it out of Share-extension handoff:

```sh
open BenchBook.app --args -BenchBookStoreName BenchBookScratch
```

## Tags

Tags are shared by every project.

- **Sidebar:** the Tags section lists the ten most used tags (Show More lists all). Click one to see everything with that tag across all projects; typing in the search field narrows it.
- **Tagging:** select tiles in the References grid (⌘-click, ⇧-click, ⌘A), then drag them onto a sidebar tag, or drag a tag onto a tile (dropping on a selected tile tags the whole selection). Right-click › Tags toggles a tag on the selection, and Project › Edit Tags… (⌃⌘T) adds and removes tags by typing.
- **Managing:** Library › Tags lists every tag with its use count and projects. Rename (renaming to an existing name merges the two), set a colour, merge several, delete, or remove unused tags.

In-app drags use private types declared in `BenchBook/Info.plist` (`com.jasonvanlint.benchbook.tag`, `com.jasonvanlint.benchbook.references`), so a dragged tag is never captured as text.

## Aftermarket

Each project's Aftermarket tab (⌘3) lists the parts for that build: name, manufacturer, product number, type, scale or the kit it fits, status, product page, an optional picture and notes. Decals are one of the types, not a separate system, and there's no library-wide stash.

- Types: Decals, Resin, Photo-etch, 3D printed, Masks, Metal parts, Wheels, Figures, Other.
- Statuses: Considering, Ordered, In stash, Using, Used, Not using. The table sorts by status by default, and the header counts parts still being considered or on order. Change a status from the table's menu, or for several parts at once by right-clicking.
- Add Part… opens the editor; double-click a part to edit it. A new part starts with the project's scale.
- A picture can be chosen, dropped (including an image dragged from a browser), or downloaded with Use Image from Product Page, which takes the image the page shows in link previews. Pictures are copied into the library like other originals; they aren't References.
- Deleting a part (Delete key, or right-click) removes its picture too. Parts are included in search.

## Search

The search field in the main window's toolbar (Edit › Find…, ⌘F) searches every project at once: project details, paints (including FS / RLM codes), aftermarket parts, and references' titles, text, notes, tags, file names, links, video channels, descriptions and moments, and the notes on boxes drawn on images. Every word must match, ignoring case, accents and punctuation ("f16" finds "F-16"). Typing part of a tag name suggests it as a token, which limits results to references with that tag. Results are grouped by project; a matching image box or video moment has its own row that opens the image zoomed to the box, or the video at that time. Right-click for Show in Project or Show in Paints.

Searchable text is prepared in memory (`SearchIndex`) and rebuilt after each save. Text inside PDFs and Markdown files, and text in images, isn't searched yet.

## Webpage previews

After a webpage link is saved, BenchBook reads the page's header for the details sites publish for link previews (Open Graph and Twitter card tags): a preview image, title, site name and description. If there's no preview image it uses the site's icon, shown at its own size; with neither, the tile keeps the globe icon. Only the HTML is read, never the page's scripts, and images are scaled down to 960 pixels before they're stored. Requests identify themselves as BenchBook; sites that refuse automated requests (some forums, Scalemates) simply get no preview. A typed title is kept; a missing title, a bare link or a host name is replaced. Like video details, previews are fetched in the background, retried at launch after network failures, and can be fetched again with Refresh Page Preview (right-click) or Refresh in the details sheet. Site names and descriptions are searchable.

## Video details

After a YouTube or Vimeo link is saved, BenchBook fetches its poster image, title, channel, length, publish date and description from the sites' public pages (oEmbed, plus the YouTube watch page). No account or API key is needed, and the video itself is never downloaded. Saving never waits for this: links saved while offline get their details the next time BenchBook launches, and right-clicking a video offers Refresh Video Details. A title the user typed is kept; a browser page title such as "… - YouTube" is replaced. Video details and webpage previews are the only network access the app makes (`com.apple.security.network.client`).

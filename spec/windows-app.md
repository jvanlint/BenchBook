# BenchBook for Windows

## Goal

A native Windows app that does what BenchBook for Mac does, looks and behaves
like a Windows app, and reads and writes the same backups so a library can move
between the two.

It follows the same principles as the Mac app:

- Saving something takes seconds and creates no homework. Tags and notes are
  optional.
- References are a visual gallery, not a table.
- The user's files are kept byte-for-byte and never changed.
- Everything stays on the user's PC. No account, no telemetry, no cloud.
- System fonts, colours, icons and standard controls.

Out of scope for the first release: sync between devices, Apple Intelligence
suggestions, and running on anything but Windows.

## Platform

- Windows 11, and Windows 10 22H2 while Microsoft supports it.
- x64 and Arm64.
- Packaged as MSIX, so it has the package identity that the Share target and
  file associations need.

## Technology

| Part | Choice | Why |
|---|---|---|
| Language | C# 13 on .NET 9 (or the current LTS at the start) | Microsoft's main stack for native apps |
| UI | WinUI 3 (Windows App SDK) | Microsoft's current native toolkit, with Fluent design and Mica |
| App structure | MVVM with CommunityToolkit.Mvvm | Microsoft-maintained; keeps logic testable without UI |
| Store | SQLite through Microsoft.Data.Sqlite | Microsoft-maintained; a single file that's easy to back up |
| JSON | System.Text.Json | Built in |
| ZIP | System.IO.Compression | Built in, with ZIP64 support |
| Hashing | System.Security.Cryptography.SHA256 | Built in |
| HTTP | HttpClient | Built in |
| Images | WinUI `Image` and Windows Imaging Component | Built in. JPEG, PNG and WebP decode out of the box. |
| PDF viewing and find | **To decide** (see [Decisions](#decisions-to-make)) | `Windows.Data.Pdf` renders pages but can't find text |
| PDF export | **To decide** | Needs a library that can draw over existing pages |
| Markdown | **To decide** | WinUI has no Markdown view |
| Tests | xUnit | |

Each library marked "to decide" is a new dependency, so it's agreed before work
starts.

### Store

The Windows app keeps its own SQLite store, with ordinary tables that mirror
the tables in [library-format.md](library-format.md): one table per record type,
`TEXT` ids, ISO 8601 dates and foreign keys with the delete rules in
[behaviour.md](behaviour.md#deleting). Its layout is private to the Windows
app. Only `library.json` is shared.

- Write-ahead logging on, foreign keys on.
- Schema changes are numbered migrations that run at launch. Back up the store
  file before running one.
- If the store can't be opened, never delete or recreate it. Show what went
  wrong, with "Show Library in Explorer", as the Mac does.

## Screens

The layout follows the Mac app, using Windows controls.

```text
┌───────────────────────────────────────────────────────────────┐
│ BenchBook                      [ Search everything…    ]  ─ □ ×│
├──────────────┬────────────────────────────────────────────────┤
│ Projects   ▾ │  F-16CJ 50th Anniversary                       │
│  F-16CJ      │  Tamiya · 1:48 · F-16CJ Block 50   [Edit]      │
│  Spitfire    │  ┌ References ┬ Paint ┬ Aftermarket ┐          │
│  …           │  [All types ▾] [cockpit ×] [decals ×]  [+ Add] │
│              │  ┌────┐ ┌────┐ ┌────┐ ┌────┐                   │
│ Paints       │  │    │ │    │ │    │ │    │                   │
│ Shopping List│  └────┘ └────┘ └────┘ └────┘                   │
│ Tags         │                                                │
│  cockpit     │                                                │
│  decals      │                                                │
│ ⚙ Settings   │                                                │
└──────────────┴────────────────────────────────────────────────┘
```

| Mac | Windows |
|---|---|
| Sidebar (`NavigationSplitView`) | `NavigationView` in left mode: projects with a status filter, Paints, Shopping List, Tags, and Settings at the foot |
| Project tabs | `SelectorBar` or `TabView` without close buttons: References, Paint, Aftermarket |
| Reference grid | `ItemsView` or `GridView` with tiles, multiple selection, a selection rectangle and keyboard navigation |
| Sheets (editors) | `ContentDialog`, or a side pane for longer editors |
| Image viewer, PDF viewer, Compare | Separate windows that remember their size and position |
| Toolbar | `CommandBar` |
| Menu bar | No menu bar. Commands live on the command bar, in right-click menus, and as keyboard shortcuts. |
| Quick Look | Open in the default app, or the built-in viewer |
| Show in Finder | Show in Explorer |
| Move to Trash | Move to the Recycle Bin |
| Settings window | Settings page in the sidebar |

### Keyboard

Mac shortcuts map ⌘ to Ctrl, with Windows conventions where they differ:

| Action | Windows |
|---|---|
| New project | Ctrl+N |
| New note | Ctrl+Shift+N |
| Add files | Ctrl+O |
| Find | Ctrl+F (also F3 for next match in the PDF viewer) |
| Edit project | Ctrl+I |
| Edit tags | Ctrl+T |
| References / Paint / Aftermarket | Ctrl+1 / Ctrl+2 / Ctrl+3 |
| Delete | Delete, with confirmation |
| Previous / next image or PDF | Ctrl+[ / Ctrl+] |
| Show or hide boxes and markups | Ctrl+B |
| Draw a box | Ctrl+D |
| Zoom in / out / to fit / actual size | Ctrl+= / Ctrl+- / Ctrl+9 / Ctrl+0 |
| Notes panel | Ctrl+Alt+I |
| Export marked-up copy | Ctrl+Shift+E |
| Previous / next PDF page | Page Up / Page Down |

## Capture

| Mac | Windows |
|---|---|
| Drag and drop | Drag and drop from Explorer and browsers: files, images, links and text |
| Paste | Ctrl+V: files, images from the clipboard, links and text |
| Add Files | File open dialog |
| Share menu extension | Share target: the app appears in the Windows share sheet for links, text and files, with a small window to pick the project, tags and a note |
| Safari text highlights | A browser extension for Edge and Chrome ("Save selection to BenchBook"), in a later phase |

Images pasted or dragged as bitmaps with no file are saved as PNG.

Like the Mac's Share extension, the Share target writes an envelope (the items,
project id, tags and note) to an inbox folder under the app's data folder, and
the running app imports it. This keeps one import path. If the app isn't
running, the envelope waits until it starts.

## Viewers

- **Image viewer**: the original file, not the thumbnail. Smooth zoom and pan
  (`ScrollViewer`), fit and actual size, note boxes drawn on a canvas over the
  image, a notes panel and an info panel (dimensions, megapixels, colour
  profile, camera data).
- **PDF viewer**: page thumbnails, zoom, find, and the note, highlight and arrow
  tools, with markups drawn on a layer over each page and never written into
  the file. Mind the coordinate flip in
  [library-format.md](library-format.md#markups).
- **Markdown**: rendered read-only, with links opening in the browser.
- **Compare**: two to four images, row or grid, each zoomable.
- **Thumbnails**: images scaled down with Windows Imaging Component; PDFs from
  page 1. Saved to `Thumbnails`, 480 px at most, PNG.

### HEIC

Windows only decodes HEIC with Microsoft's HEIF and HEVC extensions, and the
HEVC one is paid. The app must still accept, store and back up HEIC files. When
it can't decode one, the tile shows a file icon with "HEIC preview needs the
HEIF Image Extensions from the Microsoft Store", and "Open in Default App" still
works.

## Distribution and updates

- MSIX package, signed. Azure Trusted Signing is the cheapest trusted
  certificate. A self-signed package makes users install a certificate, which
  isn't acceptable.
- The Microsoft Store is the simplest route: it handles signing, installs and
  updates. A direct download from GitHub Releases can use an `.appinstaller`
  file to update itself.
- Version numbers match the Mac app's (1.x.y) when the two can read each
  other's backups. The build number counts commits, as on the Mac.

## Testing

- **Unit tests** for every rule in [behaviour.md](behaviour.md): names and
  identity keys, file checks, CSV import and export, timestamp parsing, video
  and page parsing, search folding, markup geometry and the shopping list.
- **Shared test cases** for the rules marked "stored": a JSON file of inputs and
  expected outputs, kept in `spec/`, that both apps' tests read.
- **Interop fixtures**: a small format 2 backup made by the Mac app from a
  test library (never a real one), with images, a PDF with all three markup
  kinds on a rotated page, an image with notes, paints and aftermarket items.
  The Windows tests restore it and check every value, then back it up again,
  and the Mac tests restore that.
- **Manual checks** on Windows 11 x64 and Arm64. They need a Windows PC or
  Windows 11 in a virtual machine. Code written on the Mac can't be run or
  tested there.

## Phases

1. **Format first, on the Mac.** Format 2 backup and restore in the Mac app,
   the shared test cases and the interop fixture. Without this, nobody can move
   a library across.
2. **Foundation.** The Windows project, store and migrations, the library
   folder, format 2 restore and backup, Settings, and Clean Up.
3. **Core.** Projects with status; references: capture by drop, paste and Add
   Files; the gallery with filters; notes; tags and the tag manager; moving and
   copying; search; link details and posters.
4. **Paint and parts.** The paint catalogue with CSV import and export, project
   paints, the shopping list, and aftermarket items.
5. **Viewers.** Image viewer with notes, Compare, Markdown, and the PDF viewer
   with markups and marked-up export.
6. **Getting things in.** The Share target and the browser extension.
7. **Release.** Signing, Store listing, website download link, and a Windows
   section in the README.

Phases 2 to 4 make a useful first version for testers. A beta can ship after
phase 5.

## Decisions to make

1. **PDF library.** Candidates:
   - PDFium, through a .NET wrapper (BSD/Apache licensed): rendering, text
     search and page drawing in one library. It's native code, so it needs
     x64 and Arm64 builds.
   - `Windows.Data.Pdf` for rendering, plus PDFsharp (MIT) for export. This
     has no text search, so it doesn't cover Find.
   - A paid SDK such as Nutrient or Syncfusion: complete and supported, but it
     costs money, has licence terms, and is more than BenchBook needs.

   The recommendation is PDFium, if a maintained wrapper with Arm64 builds can
   be found.
2. **Markdown rendering**: the Windows Community Toolkit's Markdown control,
   or WebView2 with a small renderer.
3. **Mac ZIP writing**: `ditto`, or a small writer on the Compression framework
   (see [Mac app changes](library-format.md#mac-app-changes)).
4. **Store or direct download**, or both.
5. **Repository**: a separate `BenchBook-Windows` repo that links back to this
   spec, or a `windows/` folder here. A folder here keeps the spec and both apps
   in one place. A separate repo keeps each history focused.
6. **Demand.** Gauge interest before phase 2, for example with a "BenchBook for
   Windows?" link on the website pointing to an issue people can vote on.

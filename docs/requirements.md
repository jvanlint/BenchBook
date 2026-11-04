# Model Research — Product Requirements

## Purpose

Model Research is a private, project-centred native macOS app for gathering and using scale-modelling research. Its defining workflow is:

```text
find useful material → save it to the active build → retrieve it at the bench
```

The working example is **Tamiya F-16CJ 50th Anniversary**, using a **Tamiya 1:48 F-16CJ Block 50** kit and **Galaxy Models 50th Anniversary 2015** decals.

## Platform

The primary product is a native macOS application, not a browser-based interface or a website wrapped in a desktop window. Its navigation, windows, menus, keyboard shortcuts, file handling, and accessibility should follow macOS conventions. Safari and Chromium extensions remain companion capture tools. SwiftUI and SwiftData are the preferred UI and persistence frameworks. The proposed baseline is a local-first library with managed image/PDF files; cloud sync, remote capture, and any hosted backend remain open decisions. See macos-architecture.md for the native design.

The HTML prototype is a visual/workflow reference only, not the implementation platform.

## Product principles

- **Capture is the core workflow.** Saving must take seconds and remember the active Project.
- **Capture creates no homework.** Notes and topics are optional; there is no mandatory inbox or classification queue.
- **Visual first.** References appear as an image-dominant gallery and lightbox, not a database table.
- **Organise only when useful.** Topics are lightweight facets, never folders.
- **Preserve assets and provenance.** Images and PDFs become durable private copies while original URLs remain available. Webpages retain URL/metadata only.
- **Keep domain meanings separate.** Real-world Colour, commercial Paint, ownership, and the Paint selected for a Project are distinct facts.

## V1 capabilities

### Projects

A Project is one intended build. V1 stores `name`, `manufacturer`, `subject`, `scale`, optional `kit number`, markings/scheme, notes, status, and cover directly rather than creating Kit, Manufacturer, Subject, or Scale taxonomy tables.

The main Project tabs are **References**, **Paint**, and **Aftermarket**. References is the default working area.

### References

Each Reference belongs to one Project and is one of:

- image: JPG, PNG, or WebP;
- PDF; or
- webpage link; or
- video link, including YouTube, with optional timestamped moments.

It may retain title, optional note, optional topics, source page URL, original resource URL, capture time, and stored-file metadata. Stored metadata includes original filename, MIME type, size, SHA-256, and image dimensions where applicable.

Images and PDFs are copied into an app-managed library in private Application Support storage. Preserve original bytes without resizing or recompressing them. SwiftData stores metadata, relationships, and relative asset locations; originals are separate files. Moving or deleting the source download must not affect a saved Reference.

The gallery uses generated thumbnails; large previews load originals on demand. PDFs use generated page previews. Thumbnails can be regenerated, while originals must be preserved. Users do not need to manage library folders or filenames.

Complete library exports/backups must include both the SwiftData records and originals. Cloud replication is an optional architecture decision. Full webpage HTML and dependent assets are not archived.

The tile gallery must support visual browsing, topic filters, an Add action, and a lightbox/side-panel with a large preview, note, topics, source link, previous/next, and preserved gallery context.

### Image inspection and native presentation

Photos are the primary reference material. Preserve their original resolution and bytes. The viewer must support smooth zoom and pan, fit-to-window, and actual-size viewing so the user can inspect a wheel, wing section, or other small detail. Inspection must use the original source rather than an enlarged thumbnail.

Use the system font, system colours, SF Symbols, and standard SwiftUI controls by default. Custom controls require an explicit discussion and agreement. Present objects as individual tiles, not freely positioned objects on an infinite canvas. Tiles show a thumbnail or type placeholder, title, clear object type, and associated topics; detailed metadata belongs in the detail view.

### Video links and timestamps

Save video URLs rather than video files. Support optional named/noted timestamped moments, especially for YouTube, stored as seconds from the start. Import recognized timestamps from supported URLs and allow manual editing/addition. Opening a supported moment should open the provider at that time. Preserve the original URL; unsupported providers may require manual seeking. Embedded playback and downloading video are outside V1.

### Search

The native app presents local, Project-scoped search results across Reference title, optional note, and Topic names. Typing `wheel well` must retrieve matching F-16 references. The same search UX should later accommodate semantic/image search without changing the user's workflow.

### Browser capture

Safari and Chromium are V1 targets and share core WebExtensions logic. Browser-specific manifests, packaging, permissions, and distribution remain separate.

The extension must:

- connect through an explicitly authorized native capture transport;
- retrieve the library's Projects and remember the active Project;
- save the current page URL/title;
- add **Save image to Model Research** to an image context menu;
- retain source page and direct image URLs separately;
- accept optional note/topics;
- hand off to the native capture/import service; and
- confirm success with an optional **View reference** action that opens the reference in the macOS app.

For images/PDFs, the browser or app acquires the bytes through the chosen capture transport. Browser-context acquisition handles resources requiring browser access. All paths use the same validation, hashing, and durable import service. Do not require a hosted download service for local capture.

### Gentle duplicates

SHA-256 may identify an exact duplicate within the same Project. Duplicate capture must not fail harshly: report **Already saved to this project** and link to the existing Reference. URL-only global and physical cross-project deduplication are deferred.

### Paint

V1 models:

- `ColourStandard` (FS, RLM, BS, ANA, RAL);
- `Colour` (for example FS 36270 Neutral Gray);
- commercial `Paint` (brand, range, code, name);
- `PaintMatch` between Colour and Paint, with match type/source/notes;
- `OwnedPaint` for user ownership; and
- `ProjectPaint` for a Project requirement, intended use, and selected Paint.

PaintMatch must allow manufacturer claims, direct matches, approximations, and mixes. The UI may start simply but must not assume a Paint has one authoritative Colour.

### Aftermarket

Aftermarket is Project-specific in V1. Items may record manufacturer, product/name number, type, scale/compatibility, status, URL, image, and notes. Decals are an Aftermarket type—not a separate subsystem.

Examples:

- Galaxy Models 50th Anniversary 2015 — Decals — 1:48 — Using
- Tamiya-compatible F-16 FOD cover — 3D printed — Considering

## Authentication and privacy

- The proposed local-only library does not require an app account.
- Browser adapters require explicit permissions and a validated transport into the app.
- Local files use macOS account/sandbox protection; URLs and IDs never authorize arbitrary file access.
- If cloud services are added, define authentication, revocation, account isolation, and private asset access separately.

## Core workflows

1. Create **Tamiya F-16CJ 50th Anniversary** with Tamiya, 1:48, F-16CJ Block 50 details.
2. Select it once in the extension.
3. Right-click a wheel-well image and save it, optionally adding `wheel well` or a note.
4. Receive a confirmation; the durable copy appears immediately in References with provenance.
5. At the bench, search `wheel well`, open the lightbox, and move through results without losing context.
6. Add FS 36270, see matching owned AK Interactive/Vallejo/Gunze/Tamiya paints, and choose one for the Project.
7. Record the Galaxy Models decals as Using and a candidate FOD cover as Considering.

## Explicit V1 non-goals

- AI, embeddings, semantic/image search, or automatic classification
- Redis, Celery, queues, or background workers
- React/Next.js or another SPA
- stash manager or kit lifecycle
- global aftermarket/decal inventory
- complex paint quantity/location/purchasing inventory
- build log, evidence/decision system, or completed-model gallery
- social, collaboration, or public sharing
- full webpage archiving
- Word, spreadsheet, or local video-file storage; video links and timestamped moments are supported
- screenshot-region, mobile-share, or bulk-tab capture
- Windows, Linux, iOS, and Android apps
- separate search service or physical global deduplication

## Genuinely open questions

- Which minimum macOS version should V1 support with SwiftUI and SwiftData?
- What window, sidebar, toolbar, menu, and keyboard interactions best support bench use?
- What local caching, offline access, and sync behaviour are required?
- How should browser connection and deep links into the app work; does any optional service require sign-in?
- How will the macOS app be signed, distributed, and updated?

1. Which Project and Aftermarket status values are the minimum useful set?
2. What authoritative/curated source supplies Colour, Paint, and PaintMatch data, including disputed matches?
3. Should initial paint data be seeded/imported, admin-managed, or user-created?
4. Should PDFs preview inline or open/download through authorized access?
5. What capture file, pixel, redirect, and timeout limits apply?
6. Does duplicate capture reuse the existing Reference or allow a second annotated record?
7. Which private/development/store distribution route is used for each browser?
8. What backup/export and account-deletion guarantees are required before broader use?

## Success criteria

V1 succeeds when the example Project can be created; Safari and Chromium capture permissions/connections can be managed independently; pages, images, and PDFs can be captured in seconds; assets remain private and durable; `wheel well` finds useful references; the gallery/lightbox works without classification chores; FS 36270 remains distinct from Paint/ownership/selection; and decals/FOD cover are tracked without introducing stash management.

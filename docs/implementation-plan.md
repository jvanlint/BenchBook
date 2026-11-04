# Model Research — Native macOS Implementation Plan

## Strategy

Use macos-architecture.md as the architecture reference for this native implementation.

Build a native macOS application in Xcode using SwiftUI and SwiftData. Start with local Project creation and the workspace shell. Then develop the core research loop: Project → capture/import → durable original → reference tile → original-resolution inspection. All phases below are native app work unless explicitly described as browser-extension work.

The HTML prototype is a visual/workflow reference. Preserve the domain scope and example Project from requirements.md.

## Phase 0 — Xcode foundation

- Create a macOS SwiftUI application target and choose/document the minimum supported macOS version.
- Add a SwiftData ModelContainer and a versioned initial schema for the Project model.
- Use system typography, system colours, SF Symbols, and standard SwiftUI controls.
- Establish a buildable app with a standard Project sidebar and native empty states.
- Keep later models and integrations out of this first slice; data-model.md describes the full destination, not a requirement to implement every entity immediately.

Accept when the Xcode project builds and launches a native macOS window. No hosted service, account, browser extension, or image subsystem is required for this phase.

## Phase 1 — Projects and workspace: first working deliverable

- Project list, Add Project form, editing, and selection in the sidebar.
- Persist name, manufacturer, subject, scale, optional kit number, markings scheme, and notes using SwiftData. Require a nonblank name; defer status values until agreed.
- Selecting a Project opens References, Paint, and Aftermarket sections, with References selected by default.
- Provide native empty states for all three sections; adding their objects comes in later phases.
- Support normal macOS menus, keyboard navigation, focus, accessibility, and explicit saves at workflow boundaries.
- Use stable UUIDs; do not automatically seed the user's library with sample records.

Accept when the user can create and edit Tamiya F-16CJ 50th Anniversary with Tamiya · 1:48 · F-16CJ Block 50, switch Projects and workspace sections, quit, relaunch, and find the saved changes intact. No separate Kit/Manufacturer/Subject/Scale taxonomy is required.

This is the scope of the initial coding-agent prompt. Stop at this reviewable deliverable before implementing later phases.

## Phase 2 — Reference library and assets

Before implementing: validate the full SwiftData relationship design from data-model.md, choose import limits, and prototype title/note/tag predicates. Establish the Application Support Library/Originals and Library/Thumbnails layout and the coordinated save/cleanup lifecycle.

- SwiftData Reference, Tag, and join models with deliberate inverses/delete rules.
- File-panel and drag/drop imports for JPG/PNG/WebP/PDF; webpage and video-link metadata entry.
- VideoMoment records with nonnegative second offsets, optional titles/notes, recognized YouTube timestamp import, manual editing, and provider playback links; no video downloads.
- Validated originals copied byte-for-byte into managed files with stable asset UUIDs; SwiftData stores metadata/SHA-256 and relative paths, without original binary payloads.
- Regenerable image thumbnails and PDF page previews; gallery uses thumbnails and loads originals on demand.
- Coordinated file/model commits, idempotent cleanup, and missing-file handling.

Accept when originals survive source-file removal and app relaunch with unchanged bytes; thumbnails can be deleted and regenerated; source and resource URLs stay separate; invalid/oversized input fails clearly; and failed saves leave no false success or permanent orphan assets.

## Phase 3 — Browser capture service

- A validated capture envelope and shared import service.
- Project discovery, persistent active Project, optional note/tags, and durable acknowledgements.
- Controlled native handoff and app-launch/recovery behaviour.
- Browser-context resource acquisition, safe app-side retrieval where used, and Project-scoped gentle duplicate detection.

Accept when duplicate capture reports Already saved to this project; rejected payloads cannot access arbitrary files; unavailable-app behaviour is explicit; and success means a durable Reference exists. Native transport authorization must be designed for the chosen browser adapter.

## Phase 4 — Safari and Chromium companions

- Shared WebExtensions capture logic with separate manifests, permissions, native adapters, and packaging.
- Save Page and Save image to Model Research context menu.
- Optional note/tags, clear failure feedback, and View Reference opening the native app.
- Safari containing app/extension and App Group handoff if selected; Chromium native host or other chosen transport.

Accept when both browsers remember the F-16 Project, capture page/image/PDF resources in seconds without classification chores, and handle browser-only resource access. Test connection/permission removal independently and capture while the app is closed. Extensions contain no library-wide arbitrary file access or cloud credentials.

## Phase 5 — Gallery, search, and reference viewer

- SwiftUI image-first tile gallery with bounded fetching, thumbnails, titles, clear object-type indicators, and tags; no infinite canvas.
- System typography and standard SwiftUI controls; custom controls require explicit agreement.
- Project-scoped title/note/tag search and optional filters behind a query service.
- Inline note/tag editing, Project cover choice, and accessible reference viewer/inspector.
- Previous/next, keyboard commands, original-resolution image viewing with smooth zoom/pan, fit-to-window and actual-size actions, provenance, and retained selection/filter context.

Accept when wheel well finds matching References, closing the viewer preserves context, and realistic libraries remain responsive without loading all originals into memory. Validate PDF viewing behaviour and macOS accessibility. Inspect small details in a large original image without substituting an enlarged thumbnail; open a saved YouTube moment at the selected timestamp.

## Phase 6 — Paint

- ColourStandard, Colour, Paint, PaintMatch, OwnedPaint, and ProjectPaint.
- Chosen import/curation flow, My Paints ownership/search, and Project selection.

Accept when FS 36270 is independent of commercial Paint; multiple sourced match claims are possible; ownership appears across Projects; and removing ownership deletes neither Paint nor a Project selection.

## Phase 7 — Aftermarket

- Project-specific items with minimum useful types/statuses, optional compatibility, image, URL, and notes.

Accept when Galaxy Models 50th Anniversary 2015 is 1:48 Decals, Using, and the FOD cover is Considering. No global stash or separate decal subsystem is introduced.

## Phase 8 — Native release and data safety

- Signing, notarization/App Store route, updates, extension installation, and supported-OS checks.
- Populated-store migration tests, export/import, consistent store-plus-originals backup/restore preserving relative paths, and missing-file recovery. Thumbnails may be omitted and rebuilt.
- Review sandbox permissions, native messages, app links, file validation, logs, and optional Keychain secrets.
- End-to-end example workflow in both browsers and the macOS app.

Accept when a signed install works through the chosen distribution route, upgrades preserve the library, a representative restore recovers records and originals, and requirements.md success criteria pass. Never reset the library to recover from a migration failure.

## Optional cloud work — separate decision gate

If cross-device sync or remote capture is required, choose CloudKit or an explicitly designed service. Validate relationship/uniqueness restrictions, conflicts, deletion propagation, asset transfer, identity, offline edits, and recovery before rollout. Cloud sync does not substitute for backup.

## Verification and scope

Verify domain integrity, migration, file/model failure recovery, browser transport, search, duplicate handling, and representative library performance. Manual acceptance includes the F-16 Project, page/image/PDF capture, wheel well search, FS 36270 Paint selection, decals, and FOD cover.

Defer AI/semantic search, full webpage archival, mobile/bulk capture, stash management, complex paint inventory, build logs, and social features. The native architecture does not expand product scope.

## Interim capture — macOS Share menu and drag and drop

Agreed ahead of Phases 3–4: browser capture starts with a macOS Share extension rather than Safari/Chromium WebExtensions.

- Drag and drop onto the workspace or a sidebar Project, paste (⌘V), and Add Files (⌘O) import directly through the shared import service.
- The Share extension writes a validated envelope (files plus JSON) to the App Group inbox and never touches the library. BenchBook imports envelopes on launch, on activation, and when the inbox changes. The extension starts BenchBook in the background after sending.
- The share sheet preselects the active Project (the last one selected in the app or shared to) from a Project list the app publishes to the App Group, and accepts optional tags and a note.
- Every item becomes a durable Reference, a gentle duplicate ("Already saved to this project"), or a reported failure before its envelope is removed.

WebExtensions capture remains Phases 3–4 and can reuse the same inbox and import path.

## Image notes — viewer with boxes and notes

Delivered ahead of the rest of Phase 5:

- Images open in their own window (other files keep Quick Look), with previous/next through the Project's images.
- Zoom and pan use AppKit's NSScrollView magnification: pinch, two-finger scroll, drag on empty space, zoom in/out, Zoom to Fit and Actual Size (one image pixel per screen pixel). The viewer shows the original, decoded upright; images over 16,384 pixels on a side are shown scaled to that GPU limit.
- Draw Box marks a feature; boxes can be selected, moved, resized and deleted, and each has a numbered note edited in a side panel. Notes are stored as ImageNote records (schema V3), never in the image.

## Paint, step 1 — catalogue and project paints

Delivered first part of Phase 6:

- Library-wide paint catalogue under Paints in the sidebar: sortable, searchable table, owned-only filter, add/edit/delete, ownership checkboxes, and CSV import.
- Each Project's Paint tab lists its chosen paints, what each is used for, and how many still need buying; paints are added from a searchable picker that can also create new catalogue paints.
- Next: ColourStandard, Colour and PaintMatch, so a Project can list the colours it needs (e.g. FS 36270) and pick matching paints.

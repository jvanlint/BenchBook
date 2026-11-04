# Model Research — macOS Architecture

## Initial implementation

Create an Xcode macOS application with SwiftUI and a SwiftData Project store. Deliver Project creation/editing, a Project sidebar, and References/Paint/Aftermarket workspace sections with native empty states first. Later sections below describe the intended architecture as those capabilities are added; they do not expand that initial task.

## Architectural direction

SwiftUI is the preferred UI framework and SwiftData is the preferred persistence framework. The proposed baseline is a local-first macOS library: structured records in SwiftData and durable images/PDFs in an app-managed file library. This baseline is an architectural recommendation; cloud sync and remote capture remain open product decisions.

This is the authoritative architecture for the native macOS implementation. Build and run the core library locally without a hosted backend or app account. Cross-device sync is a separate future decision.

```text
SwiftUI windows, sidebar, gallery, inspector, commands
                         │
                  Domain services
                  ├── SwiftData model store
                  ├── Asset library: originals + derived previews
                  ├── Search service
                  └── Capture/import service
                         ▲
             Safari / Chromium adapters
```

## Technology choices

| Concern | Preferred approach |
|---|---|
| UI | SwiftUI; AppKit integration where macOS behaviour requires it |
| Structured persistence | SwiftData ModelContainer and ModelContext |
| Originals | App-managed files under Application Support; relative asset identifiers in records |
| Previews | Generated thumbnails; PDFKit for PDF viewing where suitable |
| File import/export | System file panels and drag/drop; copy imports into the managed library |
| Credentials | Keychain if a capture transport or optional service needs secrets |
| Search | Project-scoped local search behind a dedicated query interface |
| Browser capture | Shared WebExtensions logic with browser-specific native adapters |
| Cloud services | Undecided; not required for the local library |
| Minimum OS | Decide before implementation; check availability of each selected SwiftData feature |

## Native presentation and image viewing

Use system typography, colours, SF Symbols, and standard SwiftUI controls unless a custom interaction has been explicitly agreed. The browsing model is individual object tiles with thumbnails, titles, type indicators, and tags, rather than an infinite canvas. Exact window/navigation structure remains open.

Image inspection is a core workflow: zoom/pan, fit-to-window, and actual-size viewing must draw from the preserved original. Use SwiftUI with AppKit integration as needed for responsive large-image viewing; choose the implementation after a representative image prototype. Keep zoom/pan and decoded image caches outside persisted domain models.

Video references store URLs plus structured timestamped moments, not downloaded video files. Provider adapters import timestamps and generate playback links, particularly for YouTube. Embedded playback is not required.

## Application boundaries

- Presentation: SwiftUI navigation, gallery, inspector/reference viewer, Paint and Aftermarket screens, commands, focus, and selection.
- Domain: Project operations, paint matching, duplicate policy, ownership rules, and capture validation.
- Persistence: SwiftData models, fetches, explicit saves at workflow boundaries, schema versions, and migrations.
- Assets: acquisition, validation, hashing, managed originals, thumbnails, cleanup, and export.
- Capture adapters: browser-specific transport and permissions; all imports use the same domain service.

Keep expensive downloads, hashing, image decoding, and thumbnail work off the main actor. Isolate background persistence work using suitable model contexts/model actors; pass stable IDs or value payloads between isolation boundaries. UI selection and transient window state do not belong in persisted domain models by default.

## SwiftData suitability and constraints

Projects, References, Tags, PaintMatches, ownership, and Project choices are ordinary related records and are a good candidate for SwiftData. Use explicit inverse relationships and deliberate deletion rules. Keep join entities where they carry meaning or metadata.

### Managed image and PDF library

Store original image/PDF bytes as app-managed files in the app's private Application Support directory. SwiftData stores metadata and relationships, not the original binary payload. Do not use SwiftData external binary storage for originals in this design.

Use this layout relative to the library root (extensions reflect the validated file type):

```text
Library/
  Originals/
    <asset-id>.jpg
    <asset-id>.pdf
  Thumbnails/
    <asset-id>.jpg
```

Each asset receives a stable UUID independent of its original filename. Store its relative original path/identifier in SwiftData, alongside the original filename, MIME type, byte size, SHA-256, image dimensions where applicable, and provenance. Never persist machine-specific absolute paths or temporary security-scoped URLs as the asset's permanent location. Resolve paths against the current library root.

On import or capture:

1. Acquire and stage the bytes; validate type, size, and image limits.
2. Calculate SHA-256 for Project-scoped duplicate detection and assign a stable asset ID when creating a new asset.
3. Copy the original bytes into Originals without resizing or recompressing them.
4. Save the Reference metadata and relationships in SwiftData.
5. Generate a smaller derived thumbnail for gallery browsing; PDFs use a generated page preview.

Originals are durable user data. Thumbnails are replaceable derived data and can be regenerated; thumbnail failure must not discard a successfully stored original. Load thumbnails in the gallery and the original on demand for a large preview, using appropriately sized decoding to limit memory use.

Copy user-selected files into the library rather than linking to their external location. Moving or deleting a source download must not break a saved Reference. Users add images; the app manages filenames and storage without requiring folder organisation.

File writes and model saves are not one atomic transaction. Stage and validate files, commit records deliberately, reconcile failures, and clean up unreferenced assets idempotently. Do not report capture success before both the record and original are durable. Deletion must coordinate model removal with original/thumbnail cleanup; never delete an asset that remains referenced.

A complete library export or backup must include a consistent snapshot of SwiftData records and every referenced original, preserving relative locations. Thumbnails may be omitted and rebuilt. Restore must verify that records resolve to their originals; copying only the model store is not a complete backup. The export format and snapshot mechanism remain implementation decisions.

### Search and scale

Start with title/note/tag matching and bounded fetches. Rich full-text ranking may eventually require a dedicated local search index. Prototype the actual tag relationship query and benchmark realistic libraries before choosing indexes or denormalized search text. Keep the UI independent of the query implementation. Avoid fetching full-resolution assets or the entire library into a gallery.

### Integrity and migration

Use stable UUIDs for domain identity and portable exports. Enforce same-Project covers, normalized tag names, paint identities, and gentle SHA-256 duplicate handling in domain services. Choose store constraints only after OS and sync decisions. Version the schema from the first shipped release with VersionedSchema/SchemaMigrationPlan and verify migrations on populated libraries. Backup/restore must include both the store and originals through a consistent, supported process.

### Optional sync

Local persistence, backup, and cross-device sync are separate concerns. CloudKit is an option, not an automatic requirement. Apple's SwiftData CloudKit integration does not support unique constraints and requires optional relationships; sync-aware integrity and duplicate reconciliation therefore need explicit design. Any custom cloud service would require an explicit sync protocol, conflict/deletion rules, authentication, and asset transfer. No cloud service is part of the initial implementation.

## Browser capture

Safari can communicate with its containing native app extension using native messaging; App Groups can support shared handoff data. Prefer a validated capture envelope and a controlled import path over letting several processes mutate the library without a concurrency design. Chromium needs its own native messaging host/installation adapter or another explicitly selected transport. Shared WebExtensions code does not imply identical packaging or native transport.

Define Project discovery, remembered selection, resource-byte acquisition, app launch behaviour, acknowledgements, and failure recovery before implementation. A persisted transport handoff is not a user-facing classification inbox. Never acknowledge an uncommitted handoff as a completed Reference.

Use browser-context acquisition for resources requiring browser access; never copy browser credentials into the app. Any app-side URL retrieval must enforce scheme, redirect, destination, size, pixel, and timeout limits. Keep source-page and resource URLs separate. Deep links open stable Reference IDs and never grant file access by themselves.

The initial architecture uses local native handoff; remote capture is outside the first implementation.

## Privacy, operations, and release

Use macOS sandbox entitlements deliberately, system-mediated file access, and minimal extension permissions. Local files inherit operating-system/account protection; do not describe this as application-level encryption. No app account is required by the proposed local-only library. Optional services may introduce sign-in later.

Plan signing, notarization or App Store distribution, updates, library export/import, restore, and missing-file recovery. Never delete or recreate a user's store as a migration fallback. No AI, social sharing, stash manager, or full webpage archive is introduced by the platform change.

## Decisions to resolve

1. Confirm the proposed local-first baseline and whether cross-device sync or capture while the Mac is unavailable is needed.
2. Minimum macOS version and required SwiftData feature availability.
3. Window/sidebar/inspector behaviour and keyboard commands.
4. Safari and Chromium handoff, process ownership, and distribution.
5. Export format, consistent backup/restore mechanism, and file limits; the managed Originals/Thumbnails layout is specified above.
6. Search behaviour and expected library sizes.

## Primary references

- [SwiftData](https://developer.apple.com/documentation/swiftdata)
- [External binary storage](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)
- [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)
- [SwiftData and CloudKit constraints](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [Safari native messaging and App Groups](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)

# Model Research — SwiftData Model Guide

## Implementation context

Build the native macOS app with SwiftUI and SwiftData. The models below describe a single local library, not server tables. Each persistent entity is an `@Model` class. Use `var` for persisted properties, stable UUID domain IDs, explicit relationship inverses, and deliberate delete rules. These definitions are an implementation contract, not compile-ready declarations; validate macros, predicates, and API availability against the chosen deployment target.

No User, owner foreign key, login, or ExtensionToken model is required for the local library. Browser connection is an integration concern. A future cloud service needs a separate identity/sync design, not speculative account fields throughout these models.

## Shared conventions

- Every entity has `id: UUID`, `createdAt: Date`, and `updatedAt: Date`.
- Required text uses `String`; optional text uses `String?`. Normalize blank optional text to nil.
- Use String-backed enums for reference kind, Project status, Aftermarket type/status, and match type. Final status values remain open. Where predicates require it, persist a raw String and expose a typed computed property; unknown imported values need explicit handling.
- Relationship arrays start empty. Specify inverses explicitly in model declarations.
- All dates describe facts about records; UI selection and navigation state are separate.
- Describe logical uniqueness in domain services. Do not apply `.unique` or compound uniqueness macros blindly: availability and optional future CloudKit compatibility must be assessed first.
- A domain service owns multi-record edits, validation, explicit saves, and file lifecycle coordination. SwiftUI views should not duplicate these rules.

## Relationship map

```text
Project
├── references: [Reference]
│   ├── asset: ManagedAsset?             image/PDF only
│   ├── topicLinks: [ReferenceTopic] ──> Topic
│   └── videoMoments: [VideoMoment]      video links only
├── paintRequirements: [ProjectPaint] ──> Colour
│                                       └── matches: [PaintMatch] ──> Paint
└── aftermarketItems: [AftermarketItem]                              ▲
                                                         OwnedPaint ┘
ColourStandard ──> Colour
```

## Project

| Property | Swift type | Meaning |
|---|---|---|
| name | String | Required build name |
| manufacturer, subject, scale | String | Direct descriptive fields; no taxonomy required |
| kitNumber, markingsScheme, notes | String? | Optional details |
| statusRaw | String | Typed status accessor; values to be agreed |
| references | [Reference] | Inverse: Reference.project |
| coverReference | Reference? | Must belong to this Project |
| paintRequirements | [ProjectPaint] | Inverse: ProjectPaint.project |
| aftermarketItems | [AftermarketItem] | Inverse: AftermarketItem.project |

Example: Tamiya F-16CJ 50th Anniversary; Tamiya; F-16CJ Block 50; 1:48.

## Reference

One saved object in a Project. `ReferenceKind` has `image`, `pdf`, `webpage`, and `videoLink` cases. Video links do not imply local video storage.

| Property | Swift type | Meaning |
|---|---|---|
| project | Project | Required domain relationship |
| kindRaw | String | Typed ReferenceKind accessor |
| title, note | String? | Optional description |
| sourcePageURL | URL? | Original context; required for webpage/videoLink |
| originalResourceURL | URL? | Direct image/PDF resource URL when available |
| capturedAt | Date | Capture time |
| asset | ManagedAsset? | Required for image/PDF; absent for webpage/videoLink |
| topicLinks | [ReferenceTopic] | Inverse: ReferenceTopic.reference |
| videoMoments | [VideoMoment] | Inverse: VideoMoment.reference; empty for other kinds |

Source URLs preserve provenance; never use an external URL as the only copy of a saved image or PDF. Local file imports may have no source URL. Tiles show thumbnail/preview, title, clear object type, and associated topics. A video link can use a type placeholder; remote preview artwork is optional and does not become a video archive.

## ManagedAsset

Metadata for one app-managed original file. Original bytes are not SwiftData Data properties.

| Property | Swift type | Meaning |
|---|---|---|
| originalRelativePath | String | E.g. Originals/<asset-id>.jpg, relative to library root |
| originalFilename | String? | Name provided at import |
| mimeType | String | Validated content type |
| byteCount | Int64 | Original file size |
| sha256 | String | Hash of original bytes |
| pixelWidth, pixelHeight | Int? | Image dimensions; nil for PDFs |
| references | [Reference] | Inverse: Reference.asset |
| aftermarketItems | [AftermarketItem] | Inverse: AftermarketItem.imageAsset |

`id` is the asset ID used in filenames. Originals live in private Application Support Library/Originals; generated thumbnails/PDF page previews live in Library/Thumbnails and are identified by asset ID. Derived preview paths need not be persisted. Never persist absolute library paths or temporary security-scoped source URLs.

Preserve imported bytes without resizing/recompression. Validate JPEG/PNG/WebP/PDF content, size, and pixel limits. Copy files rather than linking to downloads. Thumbnail failure must not destroy or invalidate a durable original.

Use ManagedAsset for optional Aftermarket images too; attaching one does not create a Reference. The inverse collections allow safe reference checking, but automatic cross-Project physical deduplication is not required. Do not add sharing merely because the model can represent it.

## Topic and ReferenceTopic

| Entity | Properties beyond shared fields | Rules |
|---|---|---|
| Topic | `name: String`, `normalizedName: String`, `referenceLinks: [ReferenceTopic]` | One normalized name per local library; inverse: ReferenceTopic.topic |
| ReferenceTopic | `reference: Reference`, `topic: Topic` | One link for each Reference/Topic pair |

Topics are optional facets, not folders or an inbox. Normalize case/spacing for duplicate checks. Deleting a Topic removes its links without deleting References.

## VideoMoment

A timestamped point of interest within a linked video, including YouTube. Multiple named moments may belong to one video Reference.

| Property | Swift type | Meaning |
|---|---|---|
| reference | Reference | Must have kind videoLink |
| offsetSeconds | Double | Finite, nonnegative seconds from video start; fractional seconds allowed |
| title, note | String? | E.g. Wheel-well detail |

Preserve the original source URL. When a supported YouTube URL contains a recognized timestamp, extract it into a VideoMoment. Keep normalized seconds as structured data rather than storing only a timestamped URL. Allow manual add/edit of moments. Validate against known duration when available; duration is not required to save a link.

Generate the provider-specific playback URL from the video URL and offset when the user opens a moment. Open it in the browser/provider; embedded playback and video download are not required. Format seconds as minutes/seconds or hours/minutes/seconds for display. Unsupported providers may open the original link with a clearly displayed timestamp for manual seeking; do not promise timestamp seeking for every website.

## Paint domain

| Entity | Properties beyond shared fields | Relationships and rules |
|---|---|---|
| ColourStandard | `code: String`, `name: String`, `colours: [Colour]` | Normalized code logically unique; inverse: Colour.standard |
| Colour | `standard: ColourStandard`, `code: String`, `name: String?`, `notes: String?`, `matches: [PaintMatch]`, `projectRequirements: [ProjectPaint]` | Unique standard/code; inverses: PaintMatch.colour, ProjectPaint.colour |
| Paint | `brand: String`, `range: String`, `code: String`, `name: String`, `notes: String?`, `matches: [PaintMatch]`, `ownershipRecords: [OwnedPaint]`, `projectSelections: [ProjectPaint]` | Unique normalized brand/range/code; inverses: PaintMatch.paint, OwnedPaint.paint, ProjectPaint.selectedPaint |
| PaintMatch | `colour: Colour`, `paint: Paint`, `matchTypeRaw: String`, `sourceURL: URL?`, `sourceDescription: String?`, `notes: String?` | Claims may coexist if provenance differs |
| OwnedPaint | `paint: Paint` | At most one ownership record per Paint in the library; presence means owned |
| ProjectPaint | `project: Project`, `colour: Colour`, `selectedPaint: Paint?`, `usedFor: String?`, `notes: String?` | Project intent, independent of ownership |

Match types distinguish manufacturer claim, direct match, approximation, and mix. Recipe notes suffice for initial mixes; a normalized component model and numeric confidence scale are deferred.

FS 36270 is a Colour, not a Paint. A selected Paint need not be owned. Removing OwnedPaint never deletes Paint or Project selection. A selection normally has a relevant PaintMatch; any override needs an explicit rule.

## AftermarketItem

| Property | Swift type | Meaning |
|---|---|---|
| project | Project | Required relationship |
| manufacturer, productName | String | Product identification |
| productNumber, scaleCompatibility, notes | String? | Optional details |
| typeRaw, statusRaw | String | Typed accessors; decals are a type |
| productURL | URL? | External product page |
| imageAsset | ManagedAsset? | Optional managed image; not automatically a Reference |

Examples: Galaxy Models 50th Anniversary 2015 — Decals — 1:48 — Using; FOD cover — 3D printed — Considering. Exact enum values remain to be confirmed. No global stash entity is required.

## Deletion and integrity

- Project deletion requires confirmation and cascades to its References, ProjectPaint requirements, and AftermarketItems.
- Reference deletion cascades to ReferenceTopic links and VideoMoments. Clear any Project cover relationship to it.
- Topic deletion cascades to its join links, never the References.
- Reference/Aftermarket deletion must not cascade directly to ManagedAsset. A coordinated cleanup service deletes originals, previews, and asset metadata only when no live record refers to them.
- Do not permit direct ManagedAsset deletion while referenced. Do not permit ColourStandard, Colour, or Paint deletion while used by surviving records; enforce this in domain services and compatible store rules.
- Removing ownership deletes only OwnedPaint.
- File operations and SwiftData saves are not one transaction. Stage imports, save explicitly, recover failures, and reconcile orphaned files. Success requires durable original plus durable Reference, not merely a thumbnail or queued handoff.

## Stored data versus viewer state

Persist original metadata, provenance, notes, topics, and video moments. Do not persist decoded images, SwiftUI views, thumbnail bytes, scroll positions, current selection, or image zoom/pan in the domain entities. Window restoration may separately preserve transient view state if useful.

The image viewer must use the original-resolution source, support smooth zoom and pan to inspect small details, offer fit-to-window and actual-size viewing, and retain useful navigation context. Thumbnails must never substitute for originals at inspection zoom. Decode/cache appropriate image regions or resolutions as needed; full-resolution preservation does not require keeping every image fully decoded in memory.

## Queries, migration, and recovery

Keep query logic behind services. Required access patterns include Project recency, References by Project/capture time/type, title/note/topic search, Project/SHA duplicate checks, Paint identity/matches/ownership, and Aftermarket status. Prototype relationship predicates and benchmark representative libraries before choosing SwiftData indexes or denormalized fields.

Version shipped schemas using VersionedSchema and SchemaMigrationPlan. Test upgrades with populated stores. Complete backup/export includes a consistent store snapshot and every referenced original with relative mappings; thumbnails may be rebuilt. Restore must verify file resolution. Never reset a user's store after a migration error.

CloudKit is undecided. Its optional-relationship and uniqueness restrictions would require adapting model declarations and integrity handling before enabling sync; the required relationships above express local domain rules, not a claim of CloudKit-ready declarations.

## Open implementation decisions

- Minimum macOS version and selected SwiftData API availability.
- Project and Aftermarket enum values.
- Paint data source/curation and disputed match presentation.
- Duplicate reuse versus a second annotated Reference and optional asset sharing.
- Limits, thumbnail sizes/cache policy, and large-image viewer implementation.
- Export format, consistent snapshot process, and restore UX.
- Supported video providers and their timestamp import/opening adapters.

No Kit/Manufacturer/Subject/Scale taxonomy, mandatory Inbox, stash, build log, AI annotations, full webpage archive, or local video-file library is introduced.

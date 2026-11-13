# Library and backup format

## Why a new format

BenchBook 1.0 on the Mac keeps its records in a SwiftData store and backs up
to a `.benchbookbackup` file (format 1). Neither travels:

- The store is SwiftData's internal Core Data SQLite layout (`Z`-prefixed
  tables, entity numbers, metadata blobs). It's private to Apple's frameworks
  and changes with them. Nothing else should read or write it.
- Format 1 is an Apple Archive compressed with LZFSE. Windows has no reader
  for either.

So each app keeps its own private store, and they meet in **format 2**: a ZIP
file holding the records as JSON plus the files. Each app writes format 2 when
it backs up and reads it when it restores. A Mac user moving to Windows (or
back) makes a backup on one and restores it on the other.

The Mac app needs work before this is possible (see
[Mac app changes](#mac-app-changes)). Until then, format 1 stays the Mac's only
backup format.

## The library on disk

Each app chooses where its store lives. The files beside it follow one layout,
so paths in the records mean the same thing everywhere:

```text
<library root>/
  Originals/<asset id>.<ext>      the user's files, byte-for-byte; never altered
  Posters/<reference id>.jpg      video posters and webpage previews
  Thumbnails/<asset id>.png       made from originals; can be deleted at any time
```

| | Mac | Windows (proposed) |
|---|---|---|
| Store | `~/Library/Containers/com.jasonvanlint.BenchBook/Data/Library/Application Support/BenchBook.store` | `%LOCALAPPDATA%\BenchBook\BenchBook.db` |
| Library root | `…/Application Support/Library` | `%LOCALAPPDATA%\BenchBook\Library` |

Rules:

- Paths stored in records are relative to the library root, use `/` as the
  separator on every platform, and are never absolute.
- An original's file name is its asset id plus the extension from
  [file checks](behaviour.md#files-references-accept), e.g.
  `Originals/0F8C4E2A-6B1D-4C55-9E3A-2D7B1F9A4C10.jpg`.
- A file is written to a hidden partial name in the same folder
  (`.partial-<uuid>`) and renamed into place once complete.
- A poster is named by its **Reference** id, not an asset id, and is always
  saved with a `.jpg` name. Its bytes may be PNG when the image is transparent,
  so read posters by content, not by extension.
- Thumbnails are 480 × 480 pixels at most, PNG, and never backed up.

## Format 2 backup file

A backup is one file with the extension `.benchbookbackup`. It's a standard
ZIP file (Deflate or Stored entries, ZIP64 when it's over 4 GB or 65,535 files),
laid out like this:

```text
manifest.json
library.json
Library/Originals/<asset id>.<ext>
Library/Posters/<reference id>.jpg
```

Entry names use `/` and UTF-8. Thumbnails, partial files and anything starting
with `.` are left out.

> Both formats use the `.benchbookbackup` extension, so the file's contents
> decide which it is: a ZIP file starts with the bytes `50 4B 03 04`, and
> anything else is treated as format 1. A Windows app given a format 1 backup
> says it was made by an older BenchBook for Mac, and asks for a new backup
> from the first Mac version that writes format 2.

### manifest.json

Describes the backup, so a restore can check it before touching the library.

```json
{
  "format": 2,
  "createdAt": "2026-11-13T09:41:07Z",
  "appVersion": "1.1.0",
  "platform": "windows",
  "schemaVersion": "1.0.0",
  "counts": { "projects": 4, "references": 212, "paints": 1267 },
  "files": [
    { "path": "library.json", "size": 482113, "sha256": "9f2c…" },
    { "path": "Library/Originals/0F8C4E2A-….jpg", "size": 2381904, "sha256": "41ab…" }
  ]
}
```

- `format`: always 2 for this layout. A reader rejects a higher number with
  "This backup was made by a newer version of BenchBook".
- `platform`: `"mac"` or `"windows"`. It's for messages only, never for logic.
- `files`: every entry except `manifest.json`, with its exact size and
  lowercase hex SHA-256.

### library.json

Every record in the library, as arrays of objects. Relationships are ids.
Readers ignore fields they don't know, so a newer app can add fields without
breaking an older one.

```json
{
  "schemaVersion": "1.0.0",
  "projects": [ … ],
  "references": [ … ],
  "assets": [ … ],
  "tags": [ … ],
  "referenceTags": [ … ],
  "videoMoments": [ … ],
  "markups": [ … ],
  "paints": [ … ],
  "ownedPaints": [ … ],
  "projectPaints": [ … ],
  "aftermarketItems": [ … ]
}
```

#### Value types

| Type | Written as |
|---|---|
| id | UUID string, uppercase, with hyphens: `"0F8C4E2A-6B1D-4C55-9E3A-2D7B1F9A4C10"`. Compare without regard to case. |
| date | ISO 8601 in UTC with milliseconds: `"2026-11-13T09:41:07.250Z"` |
| url | Absolute URL string |
| text | JSON string. Optional fields are left out or `null` when empty, never `""`, unless the table says empty is allowed. |
| number | JSON number. Coordinates and seconds are doubles; counts are integers. |

Every record has `id`, `createdAt` and `updatedAt`. They're not repeated in
the tables below.

#### projects

| Field | Type | Notes |
|---|---|---|
| name | text | Required, not empty. |
| manufacturer | text | Required; empty allowed. The kit's maker, e.g. "Tamiya". |
| subject | text | Required; empty allowed. e.g. "F-16CJ Block 50". |
| scale | text | Required; empty allowed. e.g. "1:48". |
| kitNumber | text? | |
| markingsScheme | text? | |
| notes | text? | |
| status | text? | `researching`, `inProgress`, `paused` or `completed`. Missing means `researching`. |

#### references

| Field | Type | Notes |
|---|---|---|
| projectId | id | Required. |
| kind | text | `image`, `pdf`, `markdown`, `webpage`, `videoLink`, `textSnippet` or `note`. Keep unknown kinds as they are (see [Compatibility](#compatibility)). |
| title | text? | |
| note | text? | The user's note about the item. |
| text | text? | The captured text (textSnippet) or the note's body (note). Up to 100,000 characters. |
| sourcePageUrl | url? | Required for `webpage` and `videoLink`. |
| originalResourceUrl | url? | The direct image or PDF address, when known. |
| capturedAt | date | When it was saved. The gallery sorts by this, newest first. |
| assetId | id? | Required for `image`, `pdf` and `markdown`; absent for the rest. |
| videoChannel | text? | Video links only. |
| videoChannelUrl | url? | |
| videoDurationSeconds | number? | |
| videoPublishedAt | date? | |
| videoDescription | text? | Up to 5,000 characters. |
| videoInfoFetchedAt | date? | Missing means "not fetched yet", so fetch when online. |
| linkSiteName | text? | Webpages only. |
| linkDescription | text? | Up to 2,000 characters. |
| linkPreviewFetchedAt | date? | Missing means "not fetched yet". |

#### assets

One per stored file. Several references may share one asset: copying a
reference to another project shares its file instead of duplicating it.

| Field | Type | Notes |
|---|---|---|
| originalRelativePath | text | e.g. `Originals/<id>.jpg`. Relative to the library root. |
| originalFilename | text? | The name the user would recognise, e.g. `wheel-well.jpg`. |
| mimeType | text | `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `application/pdf` or `text/markdown`. |
| byteCount | integer | |
| sha256 | text | Lowercase hex of the original's bytes. Used to spot duplicates. |
| pixelWidth | integer? | Images only. |
| pixelHeight | integer? | Images only. |

#### tags and referenceTags

| tags field | Type | Notes |
|---|---|---|
| name | text | As first typed, e.g. "Wheel Well". |
| normalizedName | text | See [Names](behaviour.md#names-and-duplicates). Unique in the library. |
| color | text? | `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `blue`, `indigo`, `purple`, `pink`, `brown` or `gray`. Missing means the app's accent colour. |

| referenceTags field | Type | Notes |
|---|---|---|
| referenceId | id | |
| tagId | id | One link per reference and tag pair. |

#### videoMoments

| Field | Type | Notes |
|---|---|---|
| referenceId | id | A `videoLink` reference. |
| offsetSeconds | number | From the start of the video. |
| title | text? | |
| note | text? | |

#### markups

Notes, highlights and arrows on a PDF, and note boxes on an image. The file
itself is never changed.

| Field | Type | Notes |
|---|---|---|
| referenceId | id | A `pdf` or `image` reference. |
| pageIndex | integer | Zero-based. Always 0 on images. |
| kind | text | `note`, `highlight` or `arrow`. Images only have `note`. |
| color | text | `yellow`, `orange`, `red`, `pink`, `green` or `blue`. |
| x, y, width, height | number | The area it covers. See coordinates below. |
| points | number[] | Pairs: `[x1, y1, x2, y2, …]`. A highlight's path, or an arrow's start and end. Empty for notes. |
| text | text | Empty allowed. |

Coordinates depend on the reference's kind:

- **PDF**: the page's own coordinate space in points (1/72 inch), origin at the
  **bottom left** of the page's crop box, y going up. A note's `y` is its
  bottom edge.
- **Image**: fractions from 0 to 1 of the image's width and height, origin at
  the **top left**, y going down.

Windows APIs put the origin at the top left for both, so the PDF conversion is
`windowsY = pageHeight - y - height` for a rectangle and
`windowsY = pageHeight - y` for a point. This is the most likely bug in a port.
Interop tests must cover it.

Markup numbers aren't stored. They come from sorting: PDF markups by
`pageIndex`, then `createdAt`; image notes by `createdAt`. The first is 1.

#### paints

| Field | Type | Notes |
|---|---|---|
| brand | text | Required, not empty. e.g. "Tamiya". |
| range | text | Required; empty allowed. e.g. "Acrylic XF". |
| code | text | Required, not empty. e.g. "XF-54". |
| name | text | Required; empty allowed. e.g. "Dark Sea Grey". |
| notes | text? | |
| swatchHex | text? | `#RRGGBB`, uppercase, sRGB. For recognition only. |
| standardCode | text | Required; empty allowed. Colour standards as written, e.g. "FS 36270 / BS 637". |
| identityKey | text | See [Paint identity](behaviour.md#paint-identity-stored). Unique in the library. |

#### ownedPaints

| Field | Type | Notes |
|---|---|---|
| paintId | id | At most one per paint. Its presence means the user owns the paint. |

#### projectPaints

A colour a project needs and the paint chosen for it. Either can be missing.

| Field | Type | Notes |
|---|---|---|
| projectId | id | |
| paintId | id? | The chosen paint, if any. |
| standard | text? | The colour from the painting guide, e.g. "FS 36270". |
| usedFor | text? | e.g. "Upper surfaces, pylons". |
| notes | text? | |

#### aftermarketItems

| Field | Type | Notes |
|---|---|---|
| projectId | id | |
| productName | text | Required, not empty. |
| manufacturer | text | Required; empty allowed. |
| productNumber | text? | |
| type | text | `decals`, `resin`, `photoEtch`, `printed3D`, `masks`, `metal`, `wheels`, `figures` or `other`. |
| status | text | `considering`, `ordered`, `inStash`, `using`, `used` or `notUsing`. |
| scaleCompatibility | text? | e.g. "1:48, Tamiya F-16C". |
| productUrl | url? | http or https only. |
| notes | text? | |
| imageAssetId | id? | A picture of the part. It's an asset, not a reference. |

## Writing a backup

1. Copy `Originals` and `Posters` to a staging folder, skipping hidden and
   partial files.
2. Read every record in one consistent snapshot of the store and write
   `library.json`.
3. Copy `Originals` and `Posters` again, adding files that appeared meanwhile,
   so every file the records name is in the backup.
4. Leave out files that no record names.
5. Hash every file, write `manifest.json`, and zip the folder to a temporary
   file next to the destination, then rename it into place.

The suggested file name is `BenchBook Backup YYYY-MM-DD.benchbookbackup`.

## Restoring a backup

A restore replaces the whole library. It must never leave the user with a
half-restored library or lose their current one.

1. **Check**, while the app runs normally:
   - The file is a ZIP holding `manifest.json`, and `format` is 2 or lower.
   - Extract to a staging folder beside the store, accepting only plain files
     and folders. Reject absolute paths, `..` segments, drive letters, links
     and device names. Any rejection means "This isn't a BenchBook backup, or
     it's damaged."
   - Every manifest file exists with the right size and SHA-256, and there are
     no extra files.
   - `library.json` parses, every id it references exists, and its
     `schemaVersion` is one this app can read.
   - Build a new store from it in the staging folder.
2. **Confirm**: show what the backup holds (date, app, platform, counts) and
   that the current library will be kept aside.
3. **Swap**, with the library closed (Windows: on restart, before the store
   opens):
   - Move the current store and library folder into
     `BenchBook Before Restore YYYY-MM-DD HH.mm.ss` beside them.
   - Move the staged store and folders into place.
   - If any move fails, undo every move made so far, in reverse.
4. **Tell the user** once the app opens: restored, or why not, with a way to
   show the earlier library in Explorer or Finder.

## Compatibility

- **Unknown fields**: ignore them when reading. An app that doesn't know a
  field can't keep it, so warn before restoring a backup whose `schemaVersion`
  is newer than the app's.
- **Unknown enum values** (a kind, type or status this version doesn't know):
  keep the raw text, show a sensible fallback (for example the raw text, or
  "Other"), and write it back unchanged.
- **Schema changes**: any change to the tables above raises `schemaVersion`
  and is listed here, in the same commit as the Mac change.

## Mac app changes

For both apps to share backups, the Mac app needs to:

1. Write format 2 when backing up, with `platform: "mac"`.
2. Read format 2 when restoring, building a SwiftData store from
   `library.json`, and keep reading format 1.
3. Write ZIP files without a new dependency, using either `/usr/bin/ditto`
   or a small ZIP writer built on the Compression framework's Deflate.
   This decision is still to be made.

These belong in their own issue, and they should ship before the Windows app,
so Mac users can move their libraries across on day one.

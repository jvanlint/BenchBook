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
- **Before an upgrade**, when the store is in an older schema, copy it (with
  any companion files, such as SQLite's `-wal` and `-shm`) beside it as
  `<store name> Before <new schemaVersion>.<ext>`, e.g.
  `BenchBook Before 6.0.0.store`. Copy into a hidden folder first and move
  the files into place, so a failed copy never leaves part of one. Keep an
  existing copy: it's from before the first try. If the copy fails, don't
  upgrade, and say so. The library root isn't copied; upgrades don't touch it.

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
  "schemaVersion": "6.0.0",
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
  "schemaVersion": "6.0.0",
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
  "aftermarketItems": [ … ],
  "buildPhotos": [ … ],
  "buildPhotoTags": [ … ],
  "kits": [ … ]
}
```

#### Value types

| Type | Written as |
|---|---|
| id | UUID string, uppercase, with hyphens: `"0F8C4E2A-6B1D-4C55-9E3A-2D7B1F9A4C10"`. Compare without regard to case. |
| date | ISO 8601 in UTC with milliseconds: `"2026-11-13T09:41:07.250Z"`. Round to the nearest millisecond when writing. Readers also accept dates without milliseconds. |
| url | Absolute URL string |
| text | JSON string. Optional fields are left out or `null` when empty, never `""`, unless the table says empty is allowed. |
| number | JSON number. Coordinates and seconds are doubles; counts are integers. |
| decimal | An amount of money, as a JSON string with a full stop and no currency, e.g. `"18.50"`, so it's never rounded. |

Every record has `id`, `createdAt` and `updatedAt`. They're not repeated in
the tables below. A project's `updatedAt` follows the rule in `behaviour.md`
(When a project was last updated).

#### projects

| Field | Type | Notes |
|---|---|---|
| name | text | Required, not empty. |
| subject | text | Required; empty allowed. What the model shows, e.g. "F-16CJ Block 50". |
| markingsScheme | text? | |
| notes | text? | |
| status | text? | `researching`, `inProgress`, `paused` or `completed`. Missing means `researching`. |
| projectPhotoId | id? | A build photo of this project, shown in its header. Missing, or the id of a photo that no longer exists, shows none. Schema 2. |

A project's kits are the `kits` records whose `projectId` is its id. Schema 4
removed `manufacturer`, `scale` and `kitNumber` (see Compatibility).

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
References, aftermarket items, build photos and kits all point at assets; an
asset is deleted, with its file, only when none of them use it.

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

| buildPhotoTags field | Type | Notes |
|---|---|---|
| buildPhotoId | id | Schema 2. |
| tagId | id | One link per build photo and tag pair. |

A tag is in use while any reference or build photo has it. "Remove unused
tags" never deletes a tag that only build photos use.

#### videoMoments

| Field | Type | Notes |
|---|---|---|
| referenceId | id | A `videoLink` reference. |
| offsetSeconds | number | From the start of the video. |
| title | text? | |
| note | text? | |

#### markups

Notes, highlights and arrows on a PDF, and note boxes on an image or a build
photo. The file itself is never changed.

| Field | Type | Notes |
|---|---|---|
| referenceId | id? | A `pdf` or `image` reference. Exactly one of `referenceId` and `buildPhotoId` is set. |
| buildPhotoId | id? | A build photo. Its markups are always `note`s on page 0, positioned like an image's. Schema 2. |
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
- **Image** and **build photo**: fractions from 0 to 1 of the image's width
  and height, origin at the **top left**, y going down.

Windows APIs put the origin at the top left for both, so the PDF conversion is
`windowsY = pageHeight - y - height` for a rectangle and
`windowsY = pageHeight - y` for a point. This is the most likely bug in a port.
Interop tests must cover it.

Markup numbers aren't stored. They come from sorting: PDF markups by
`pageIndex`, then `createdAt`; image and build photo notes by `createdAt`.
The first is 1.

#### paints

| Field | Type | Notes |
|---|---|---|
| brand | text | Required, not empty. e.g. "Tamiya". |
| range | text | Required; empty allowed. e.g. "Acrylic XF". |
| code | text | Required, not empty. e.g. "XF-54". |
| name | text | Required; empty allowed. e.g. "Dark Sea Grey". |
| notes | text? | |
| swatchHex | text? | `#RRGGBB`, uppercase, sRGB. For recognition only. |
| standardSystem | text | Required; empty for none. A [standard system](behaviour.md#paint-standards) raw value, e.g. "fs595". |
| standardCode | text | Required; empty allowed, and empty when there's no system. The code within the system, e.g. "36270"; for Multiple and Custom, the whole text, e.g. "FS 36270 / BS 637". |
| match | text | Required; empty for not set, and empty when there's no system. "none", "closest" or "exact". |
| type | text | Required; empty for not set. A [paint type](behaviour.md#paint-types) raw value, e.g. "lacquer". |
| isMix | boolean | Required. True for a [custom mix](behaviour.md#mixes-stored), whose code may be empty. |
| identityKey | text | See [Paint identity](behaviour.md#paint-identity-stored). Unique in the library. |

#### ownedPaints

| Field | Type | Notes |
|---|---|---|
| paintId | id | At most one per paint. Its presence means the user owns the paint. Never present for a mix. |

#### paintMixParts

One line of a mix's recipe. Deleting the mix deletes its lines.

| Field | Type | Notes |
|---|---|---|
| mixId | id | A paint with `isMix` true. |
| paintId | id | A paint with `isMix` false, not the mix itself. Once per mix. |
| parts | number | A double, more than zero, e.g. `3` or `1.5`. |
| position | number | An integer, the line's place in the recipe, from 0. |

#### projectPaints

A colour a project needs and the paint chosen for it. Either can be missing.

| Field | Type | Notes |
|---|---|---|
| projectId | id | |
| paintId | id? | The chosen paint, if any. |
| standardSystem | text | Required; empty for none. The guide colour's standard system, as for paints. |
| standard | text? | The guide colour's code, e.g. "36270", split as for paints. Nil when there's no system. |
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

#### buildPhotos

The user's own photos of a build: work in progress and the completed model.
They're kept apart from references, which hold research. Schema 2.

| Field | Type | Notes |
|---|---|---|
| projectId | id | Required. |
| assetId | id | Required. Always an image: `image/jpeg`, `image/png`, `image/webp` or `image/heic`. |
| notes | text? | The first line is shown under the photo as its caption. |
| takenAt | date | From the photo's EXIF `DateTimeOriginal` (or `DateTimeDigitized`) when it's added, read as local time; otherwise when it was added. The user can change it. |
| stage | text | `wip` or `completed`. Unknown values show as `wip` and are kept. |

Order: `completed` photos first, then `wip`; within each, `takenAt` newest
first, then `createdAt` newest first. The grid groups `wip` photos by the day
of `takenAt`, in the device's time zone.

One file can be a build photo and a reference in the same project; each
keeps its own asset. Adding the same file (same `sha256`) twice to one
project's build photos is refused as a duplicate.

#### kits

Model kits the user owns or wants, in the library's catalogue. Each record
is one physical kit: two boxes of the same kit are two records, each with its
own status and price. A kit can be in one project at most. Schema 3.

| Field | Type | Notes |
|---|---|---|
| brand | text | Required, not empty. e.g. "Italeri". |
| name | text | Required, not empty. The product's name as on the box, e.g. "Super Cobra". |
| scale | text? | e.g. "1:72". |
| number | text? | The maker's number. Text, so leading zeros and dashes are kept: "07109", "85-5444". |
| owned | boolean | `false` for a kit the user wants but hasn't got. |
| status | text | `bnib` (brand new in box), `opened`, `wip` or `built`. Unknown values show as `bnib` and are kept. |
| rating | integer? | 1 to 5 stars. Other values read as no rating. |
| link | url? | http or https only. Scalemates, a shop or the maker. |
| pricePaid | decimal? | In the library's one currency, which isn't stored. |
| forSale | boolean | |
| salePrice | decimal? | Kept when `forSale` is `false`. |
| notes | text? | |
| pictureAssetId | id? | Box art. An asset, not a reference. Copies of a kit can share one asset. |
| projectId | id? | The project building this kit. Missing means it's in no project. Deleting the project leaves the kit, with this missing. Schema 4. |

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
   - Every manifest path is relative, with no empty, `.` or `..` parts, so it
     stays inside the staging folder. Every manifest file exists with the
     right size and SHA-256, and there are no extra files.
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

## Project file

One project, moved between libraries: from one Mac to another, from a Mac to
Windows, or back. Unlike a restore, importing one **adds to** the library and
never replaces it. Both apps must write files the other can import.

The extension is `.benchbookproject` (type `com.jasonvanlint.benchbook.project`,
conforming to `public.data` and `public.archive`, not `public.zip-archive`, so
Finder and Explorer don't offer to unzip it). It's a **standard ZIP**, the same
container as a format 2 backup:

```text
manifest.json
library.json
Library/Originals/<asset id>.<ext>
Library/Posters/<reference id>.jpg
```

### The ZIP container

- **Writers store entries without compression** (method 0). The files are
  photos, PDFs and HEIC, which are compressed already, and stored entries make
  writing simple and fast. On Windows, `ZipArchive` with
  `CompressionLevel.NoCompression` writes them.
- **Readers accept stored and Deflate** (method 8) entries, in case a file was
  zipped again with another tool. Any other method, encryption, or a
  multi-part archive is refused.
- Entry names are UTF-8 (flag bit 11 set) with `/` separators. ZIP64 is used
  when an entry, an offset or the central directory passes 4 GB, or there are
  over 65,535 entries.
- Entries are plain files, mode `0644` when the writer records Unix modes. No
  folders are needed; a reader ignores folder entries.
- The Mac writes its own ZIPs (`ZipArchive.swift`, on Foundation and the
  Compression framework). `ditto` isn't used. Each entry's CRC-32 is checked
  when it's read.

### manifest.json

As for a backup, with `kind` and `includesPersonalDetails`:

```json
{
  "format": 2,
  "kind": "project",
  "createdAt": "2026-11-23T09:41:07.250Z",
  "appVersion": "1.3.0",
  "platform": "mac",
  "schemaVersion": "6.0.0",
  "includesPersonalDetails": false,
  "counts": { "projects": 1, "references": 212, "buildPhotos": 14, "paints": 30,
              "aftermarketItems": 4, "kits": 1 },
  "files": [
    { "path": "library.json", "size": 48211, "sha256": "9f2c…" },
    { "path": "Library/Originals/0F8C4E2A-….jpg", "size": 2381904, "sha256": "41ab…" }
  ]
}
```

- `kind` is `"project"`. A file without it, or with another kind, isn't a
  project file ("This isn't a BenchBook project file, or it's damaged.").
- `format` higher than 2: "This project was exported by a newer version of
  BenchBook. Update BenchBook, then import it."
- `counts` are for the import summary only.

### library.json

The [same tables and fields](#libraryjson) as a backup, holding one project
and what it uses:

| Table | What's included |
|---|---|
| projects | The one project. `projectPhotoId` only if that photo is in the file. |
| references, videoMoments, markups | All of the project's, with markups on its build photos too. |
| referenceTags, buildPhotoTags, tags | The project's tag links, and the tags they use. |
| buildPhotos | All of the project's. |
| projectPaints | All of the project's, with or without a paint. |
| paints | The paints chosen in its paint list, and for a chosen mix the paints in its recipe. |
| paintMixParts | The recipes of those mixes. |
| ownedPaints | Only with personal details: whether the user owns those paints. |
| aftermarketItems | All of the project's. |
| kits | The kits in the project. `pricePaid` and `salePrice` only with personal details; without them `forSale` is `false`. |
| assets | Every asset those records use: reference files, build photos, aftermarket pictures, kit box art. |

Records are written oldest first (`createdAt`, then `id`), so the same project
always gives the same file. **Dates are rounded to the millisecond** when
written, so reading and writing a date again gives the same text.

**Personal details** (kit prices, for sale, paint ownership) are left out
unless the user asks. Everything else is always included.

### Importing

1. **Check**, without touching the library, as for a restore: extract to a
   staging folder, accepting only safe names (no absolute paths, `..`,
   backslashes, drive letters or links); every manifest file exists with the
   right size and SHA-256; there are no files the manifest doesn't list; and
   `library.json` holds exactly one project, with every id a record points at
   in the file. Each asset's path is `Originals/<name>`. Otherwise: "This isn't
   a BenchBook project file, or it's damaged." A wrong checksum names the
   file: "This project file is damaged: “…” doesn't match what was exported.
   Nothing was imported."
2. **Same project?** If the library has a project with the file's project id
   (it was exported from this library, or went to another and back), ask:
   **Replace** it with the file's version, or **Keep Both**. Otherwise import
   straight away.
3. **Merge**, all in one save, so it all imports or nothing does:
   - **Ids** are kept, so a project that goes Mac → Windows → Mac is still the
     same project. An id already used by another record in the library gets a
     new one. With **Keep Both**, every record of the project gets a new id and
     the project's name gets " Copy" after it ("F-16C Viper Copy").
   - **Replace** deletes the library's project first (as Delete Project does:
     its kits leave it, its files go if nothing else uses them, its posters
     go), then adds the file's.
   - **Files** (assets): an asset whose id and SHA-256 are already in the
     library is shared, not copied again. Otherwise the file is copied into
     `Originals` under its asset id (a new id if that one's taken).
   - **Tags** match by normalized name. A tag already in the library is used as
     it is, keeping its colour; a new one keeps the file's colour.
   - **Paints** match by identity key, recomputed from brand, range and code
     (brand and name for a mix). A paint already in the catalogue is used as
     it is and never changed. A new paint is added with the file's details,
     owned only if `ownedPaints` lists it; a new mix gets its recipe.
   - **Kits** are physical boxes, so they're never copied. A kit whose id is
     in the library joins the imported project if it's in no project (or in
     the project being replaced); if another project is building it, it stays
     there and the summary says so. Other kits are added.
   - The project and its records keep the dates in the file. Importing doesn't
     count as editing the project, so "last updated" isn't changed.
4. **Posters** are copied after the save, named by the imported reference's
   id. They're previews, so a missing one isn't an error.
5. **Summary**: the project's counts, paints added and already there, new
   tags, kits added and already there, and kits that stayed in another
   project.

The suggested file name is the project's name with `/ \ : * ? " < > |` and
line breaks replaced by `-`, e.g. `F-16C Viper.benchbookproject`.

## Compatibility

- **Unknown fields**: ignore them when reading. An app that doesn't know a
  field can't keep it, so warn before restoring a backup whose `schemaVersion`
  is newer than the app's.
- **Unknown enum values** (a kind, type or status this version doesn't know):
  keep the raw text, show a sensible fallback (for example the raw text, or
  "Other"), and write it back unchanged.
- **Schema changes**: any change to the tables above raises `schemaVersion`
  and is listed here, in the same commit as the Mac change.

| schemaVersion | Change |
|---|---|
| 1.0.0 | BenchBook 1.0. |
| 2.0.0 | Build photos (#43): `buildPhotos`, `buildPhotoTags`, `projects.projectPhotoId`, `markups.buildPhotoId`; `markups.referenceId` becomes optional. Additive: a 1.0.0 library reads as 2.0.0 with no build photos. |
| 3.0.0 | Kits (#41): `kits`, and the `decimal` value type. Additive: a 2.0.0 library reads as 3.0.0 with no kits. |
| 4.0.0 | Projects use kits (#44): `kits.projectId`; `projects.manufacturer`, `projects.scale` and `projects.kitNumber` are removed. Upgrading a 3.0.0 library (or reading an older backup) adds a line to the end of each project's notes with whichever of those three are filled in, `Kit: <manufacturer> · <kitNumber> · <scale>`, after a blank line, unless it's already the last line. Not localized. No kits are created. |
| 5.0.0 | Paint standards, match and type (#42): `paints.standardSystem`, `paints.match`, `paints.type`, `projectPaints.standardSystem`. Upgrading a 4.0.0 library (or reading an older backup) splits each `paints.standardCode` and `projectPaints.standard` into a system and a code, following [Reading standard text](behaviour.md#reading-standard-text). Nothing is lost: text that isn't recognised is kept whole as Multiple or Custom. Match and type start empty. |
| 6.0.0 | Custom mixes (#42): `paints.isMix`, `paintMixParts`. Additive: a 5.0.0 library reads as 6.0.0 with no mixes. |

## Mac app changes

For both apps to share backups, the Mac app needs to:

1. Write format 2 when backing up, with `platform: "mac"`.
2. Read format 2 when restoring, building a SwiftData store from
   `library.json`, and keep reading format 1.
3. Write ZIP files without a new dependency. **Decided (#12):** a small
   built-in writer that stores entries, and a reader for stored and Deflate
   entries (`ZipArchive.swift`), as [Project file](#project-file) describes.
   Project export and import already use them, with the format 2 records.

These belong in their own issue, and they should ship before the Windows app,
so Mac users can move their libraries across on day one.

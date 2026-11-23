# Behaviour

These are the rules every version of BenchBook follows. Where a rule affects
stored data, such as a normalized name, a version that gets it wrong will
create duplicates or miss matches when it opens a backup from the other
platform. Those rules are marked **(stored)** and need tests that use the same
inputs on both platforms.

Text functions are Unicode-aware and locale-independent: "lowercase" means
Unicode default lowercasing (`ToLowerInvariant` in .NET), and "whitespace"
means any Unicode whitespace, including line breaks.

## Names and duplicates

### Tags (stored)

- **Parsing** a tag field such as `" wheel   well, Cockpit ,, WHEEL WELL ,decals "`:
  split on commas, collapse each piece's whitespace runs to single spaces and
  trim, drop empty pieces, and drop later pieces whose normalized form was
  already seen. Result: `["wheel well", "Cockpit", "decals"]`.
- **Normalized name**: collapse whitespace as above, then lowercase.
  `"  Wheel   Well "` → `"wheel well"`.
- A library has one tag per normalized name. Typing an existing name, in any
  case, reuses that tag and keeps its original spelling.
- Renaming a tag to another tag's name merges them: the links move to the
  other tag, which takes the new spelling, and the renamed tag is deleted.
- Merging keeps the target's colour, or takes the first colour among the merged
  tags if it has none.
- Tags are shared by references and build photos. Renaming, merging,
  colouring and deleting a tag affect both.
- "Remove unused tags" deletes tags with no links, counting both reference
  links and build photo links. A tag only build photos use is in use.
- Tags sort by how many references and build photos use them (most first),
  then by name. Counts read "12 references, 4 build photos", leaving out
  zeros and using the singular for one.

### Paint identity (stored)

A paint's `identityKey` is `brand|range|code` after folding:

- brand and range: collapse whitespace, trim, lowercase.
- code: lowercase, then remove whitespace and the characters `- _ . /`.

So "Tamiya", "Acrylic XF", "XF-54" gives `tamiya|acrylic xf|xf54`, and
"XF 54" or "xf54" give the same key. A library holds one paint per key.
Creating or editing a paint whose key belongs to another paint is refused:
"*Tamiya XF-54 Dark Sea Grey* is already in your catalogue."

A mix is known by brand and name instead, as its code is optional:
`mix|<brand>|<name>`, both folded as above. So "Custom", "Faded Sky Grey"
gives `mix|custom|faded sky grey`.

### Mixes (stored)

A **mix** is a paint the user mixes from other catalogue paints, with a
recipe. It's in the catalogue like any paint, and can be chosen for a
project's colour.

- It needs a brand (e.g. "Custom", or the user's name) and a name. Its code
  is optional, and it has no range.
- It has a standard, match, type, swatch and notes like any paint. Its
  swatch is set by the user; it isn't worked out from the recipe.
- **Recipe**: catalogue paints that aren't mixes, each once, with a number of
  parts more than zero (a double, e.g. 3 or 1.5), in the user's order. A
  recipe can be empty while the user works it out.
- **Owned**: a mix has no ownership of its own. It counts as owned when its
  recipe has paints and the user owns every one. Its Owned tick box can't be
  ticked; its help says which paints are missing ("Not owned yet: Tamiya
  XF-19 Sky Grey").
- **Changes for one project**, such as "lightened 20% for fading", go in that
  project's notes for the colour. A project can't change a recipe; a
  different recipe is another mix.
- Shown as "Mix: 3 parts XF-2, 1 part XF-19" where a paint shows its range:
  "1 part" for exactly one, otherwise the number with up to two decimals and
  "parts". Each paint is its code, or its name if it has no code.
- Mixes aren't in the paint CSV. Backups keep them.

### Paint search

A paint matches a query when brand, range, code, name or standard contains it,
ignoring case. The standard is its shown text plus the system's name, e.g.
"FS 36270 FS 595", so "FS 595" finds every FS paint. A standard also matches
with spaces and punctuation removed from both, so "FS 36270" finds "FS36270"
and "FS-36270 / BS 637".

### Paint standards (stored)

A paint, and a colour in a project's painting guide, can follow a colour
standard: a **system** and a **code** within it. Most paints have none.
Systems are stored by raw value, in this menu order:

| Raw value | Menu name | Shown prefix | Reference system: main subjects |
|---|---|---|---|
| `fs595` | FS 595 | FS | FS 595 / AMS-STD-595: modern military aviation |
| `ral` | RAL | RAL | RAL Classic: German armour and military vehicles |
| `rlm` | RLM | RLM | RLM: WWII Luftwaffe |
| `bs381c` | BS 381C | BS | BS 381C: British military aircraft |
| `ana` | ANA | ANA | ANA: WWII US aviation |
| `map` | MAP | MAP | MAP: WWII RAF and Fleet Air Arm |
| `bulletin41` | Bulletin 41 | Bulletin 41 | USAAF Bulletin 41: WWII US Army aircraft |
| `amt` | AMT / A-series | none | AMT / AII / A-series: Soviet WWII aviation |
| `ijn` | IJN / IJA | none | IJN / IJA: Japanese WWII aviation |
| `tavola10` | Tavola 10 | Tavola 10 | Tavola 10: Italian WWII aviation |
| `raafK3` | RAAF K3 | K3 | RAAF K3: Australian WWII aircraft |
| `ships2` | SHIPS-2 | none | US Navy SHIPS-2: WWII American warships |
| `multiple` | Multiple | none | More than one standard, written out |
| `custom` | Custom | none | Any other standard, written out |

- No system (empty) means no standard. Then the code and match are empty.
- **Shown** as the prefix, a space and the code: "FS 36270", "RLM 76",
  "BS 640". Systems without a prefix show the code alone ("J3", "5-N",
  "FS 36375 / BS 637"). A system with no code shows its menu name ("RLM").
  Prefixes and system names aren't localized, except Multiple and Custom.
- An unknown system shows as Custom, with its code, and is kept.
- **Matching** a paint to a guide colour: both shown texts are lowercased with
  everything but letters and digits removed, and the systems must be the same,
  so "FS 36270" and "FS36270" match. Multiple and Custom match on the text
  alone. When choosing a paint for a colour, paints with its standard come
  first, best match first.

**Match** says how closely a paint follows its standard: `none` (No Match),
`closest` (Closest Match) or `exact` (Exact Match). Empty is Not Set. It's
only shown, and only kept, when the paint has a standard. A guide colour has
no match.

### Reading standard text (stored)

Used by the 5.0.0 upgrade, and by CSV columns that hold a whole standard such
as "FS 36270". Trim the text; empty means no standard. Then, in order:

1. If it contains any of `/ , ; & +`, it's several: Multiple, with the whole
   text as the code.
2. If it starts with `IJN` or `IJA`: IJN / IJA, with the whole text as the
   code, as the prefix says which service.
3. If it starts with one of these prefixes, ignoring case, longest first:
   `AMS-STD-595`, `AMS STD 595`, `FS 595`, `FS-595`, `FS595` (FS 595);
   `BS 381C`, `BS-381C`, `BS381C`, `BS 381`, `BS381`, `BSC` (BS 381C);
   `FS` (FS 595); `RAL`; `RLM`; `BS` (BS 381C); `ANA`; `MAP`. A letter can't
   follow the prefix ("Maple" isn't MAP). A digit can ("FS36270"), except
   after a prefix ending in a digit or `381C`. The code is the rest, without
   leading spaces or `- : # .`.
4. Anything else: Custom, with the whole text as the code.

So nothing is lost: "FS 36375 / BS 637" becomes Multiple, and "Humbrol 28"
becomes Custom.

### Paint types (stored)

What a paint is made with, so the user picks the right thinner. Optional;
BenchBook never guesses it from the brand or range. In menu order:

| Raw value | Shown | CSV name | Hint |
|---|---|---|---|
| `waterAcrylic` | Water-Based Acrylic | Water-based acrylic | Low odour, fast drying, water cleanup. Vallejo Model Color, AK 3rd Gen, Ammo MIG, Citadel, Mr. Hobby Acrysion. |
| `alcoholAcrylic` | Alcohol-Compatible Acrylic | Alcohol-compatible acrylic | Fast drying, excellent for airbrushing. Tamiya X/XF, Mr. Hobby Aqueous. |
| `lacquer` | Lacquer | Lacquer | Solvent-based, hard finish. Mr. Color, Tamiya LP, MRP, AK Real Colors. |
| `enamel` | Enamel | Enamel | Solvent-based, slower drying. Humbrol Enamel, Tamiya Enamel, Revell Email Color. |
| `oil` | Oil Paint | Oil paint | Very slow drying, for weathering. Abteilung 502, Winsor & Newton. |
| `polyurethane` | Polyurethane-Based Paint | Polyurethane-based paint | Primers and coatings. Vallejo Surface Primer. |
| `acrylicWash` | Acrylic Wash | Acrylic wash | Thin, water-based, for panel lines and shading. Vallejo Model Wash, Citadel Shade, AK Acrylic Wash. |
| `enamelWash` | Enamel Wash | Enamel wash | Thin, solvent-based, wiped back with enamel thinner. Ammo MIG Panel Line Wash, AK Interactive washes, Tamiya Panel Line Accent Color. |
| `pigment` | Pigment | Pigment | Dry powders for dust, mud and rust. MIG Productions, AK Interactive Pigments, Vallejo Pigments. |
| `marker` | Marker | Marker | Paint or ink in a pen, for details and touch-ups. Gundam Marker, Molotow Liquid Chrome, Tamiya Paint Marker. |
| `other` | Other | Other | Inks, metal waxes and so on. |

Empty is Not Set. An unknown type shows as Not Set and is kept. The hint is
the menu item's help text.

Editing a paint writes its system, match and type only when the user changes
them, so values this version doesn't know are kept.

### Swatches

A swatch accepts `#RRGGBB`, `RRGGBB` or `#RGB`, and is stored as uppercase
`#RRGGBB`. Anything else isn't a colour.

**Clear paints** are drawn as glass wherever a swatch appears: the swatch
colour at 55% opacity over a faint checkerboard, with a soft white highlight
across the top. A clear with no swatch colour is drawn as clear (white) glass.
A paint is a clear when its name, split into words at anything that isn't a
letter, has the word "clear", ignoring case and accents: "Clear", "Flat
clear", "Clear Red", "Semi-Gloss Super Clear". "Unclear" and "Clearcoat"
aren't. Nothing is stored.

## Files references accept

A file is checked by its **contents**, not its name, except Markdown, which has
no signature.

| Kind | Recognised by | Stored as |
|---|---|---|
| JPEG | starts `FF D8 FF` | `image/jpeg`, `.jpg` |
| PNG | starts `89 50 4E 47 0D 0A 1A 0A` | `image/png`, `.png` |
| WebP | bytes 0–3 `RIFF` and 8–11 `WEBP` | `image/webp`, `.webp` |
| HEIC | bytes 4–7 `ftyp`, and bytes 8–11 one of `heic heix heim heis mif1 msf1` | `image/heic`, `.heic` |
| PDF | `%PDF-` within the first 1,024 bytes, and at least one page opens | `application/pdf`, `.pdf` |
| Markdown | extension `md`, `markdown`, `mdown` or `mkd`, and valid UTF-8 | `text/markdown`, `.md` |

Limits:

- Files: up to 200 MB. Markdown files: up to 5 MB. Images: up to 300 megapixels.
- Empty files, folders and unreadable images are refused.
- Images must report a width and height greater than 0. Both are stored.

Error messages (keep the meaning; the wording can follow the platform):

- "“name” isn't a supported file. BenchBook accepts JPEG, PNG, WebP and HEIC images, PDFs and Markdown files."
- "“name” couldn't be read. It may be damaged or empty."
- "“name” is too large. Files can be up to 200 MB, and Markdown files up to 5 MB."
- "“name” has too many pixels. Images can be up to 300 megapixels."

## Capture

Every way in (drop, paste, Add Files, the share target, a browser extension)
goes through one import path:

1. **Files**: check the file, hash it (SHA-256). If the project already has a
   reference with that hash, it's a duplicate: nothing is added and the user is
   told "“title” is already saved to this project." Otherwise copy the file into
   `Originals` under a new asset id, then save the asset and reference together.
   If saving fails, delete the copied file. When the capture says which page
   the file came from, such as the page an image was on, it's saved as the
   reference's source page, and the file's own address as its original address.
2. **Links**: http or https only, with a host. If the project already has a
   webpage or video link with exactly the same address, it's a duplicate, as
   for files. A YouTube or Vimeo address (see [Video links](#video-links))
   becomes a `videoLink`, anything else a `webpage`. A video link with a
   timestamp also gets a moment at that time. Addresses that differ in any way,
   such as a different timestamp, are different links.
3. **Text**: trimmed, refused if empty, cut to 100,000 characters, saved as a
   `textSnippet` with its source page if known.

A capture can carry tags and a note, which apply to every item in it. A batch
reports failures and duplicates in one message at the end. Successful items stay
saved even when others fail.

After a link is saved, its details are fetched in the background (see
[Link details](#link-details)). Saving never waits for the network.

The same file in two projects is two references with two assets. Only copying
a reference shares an asset.

### Browser extension

The Mac has a Safari extension, inside BenchBook.app. Its right-click menu has
Save Page to BenchBook, Save Image to BenchBook and Save Selection to
BenchBook. Each saves straight away, with no dialog, to the project last used
in BenchBook or in the extension. Save Page on a PDF saves the PDF file. The
toolbar button opens a panel to choose the project and add tags and a note.

- **Downloads**: the extension downloads images and PDFs itself, with the
  browser's cookies, so pages the user is signed in to work. Files can be up
  to 200 MB. Text keeps its line breaks.
- **Handing over**: like the Share extension, it never writes to the library.
  It leaves an envelope in the inbox, marked as from Safari, and starts
  BenchBook in the background.
- **Reading the inbox**: BenchBook skips an envelope folder that's a link,
  refuses an envelope file that's a link or larger than 1 MB, and ignores a
  named file that's a link or whose name has a `/` or is `.`, `..` or empty.
  The extensions only ever write real files, so anything else wasn't theirs.
- **Result**: after importing an envelope from Safari, BenchBook writes its
  result for the extension: saved (with the references added), already in
  this project, or failed with the reason. The extension waits up to 5 seconds
  for it. If none comes, it says "Sent to BenchBook", and BenchBook reports
  any problem itself when it imports. Because Safari shows the outcome,
  BenchBook doesn't also show an alert for duplicates from Safari; it still
  does for failures.
- **Change…**: after a save, the notice's Change… moves what was saved to
  another project, adds tags to its own, and adds the note after any note it
  has. After "already in this project", Change… saves it to another project.
- **Checks**: BenchBook checks every message from the extension: web
  addresses must be http or https, file names lose any folders and leading
  dots, and text, notes and tags are cut to their limits. Anything else is
  refused.

Windows plans an Edge and Chrome extension in a later phase; it should behave
the same way.

### Notes

A note is a reference of kind `note` that the user writes in BenchBook. It
needs a title or some text ("Write a title or some text for the note."). Its
body keeps line breaks and indentation, trimmed only at the ends.

## Build photos

A project's Build Photos section holds the user's own photos of the build,
apart from its references.

- **Adding**: drop, paste, Add Photos… (file picker), Import from Photos…
  (the system photo picker, which needs no access to the whole library), or a
  photo taken with an iPhone or iPad camera (Continuity Camera: File › Import
  from iPhone or iPad). A camera photo goes to the editor's picture when a kit
  or aftermarket editor is in front, otherwise to Build Photos when it's
  showing in the front window; with neither, the menu item is unavailable.
  Its original name is "Camera Photo". Document scans aren't taken. Windows
  has no equivalent and can leave this out.
  While Build Photos is showing, drops and pastes go there instead of
  References. Each file is checked like a reference file, and only images are
  accepted: anything else is reported as "“name” isn't a photo." The original
  is copied byte for byte, location data included.
- **Duplicates**: a file whose SHA-256 matches one of the project's build
  photos is refused: "“name” is already in this project's build photos." The
  same file can still be a reference too.
- **Date taken**: EXIF `DateTimeOriginal`, else `DateTimeDigitized`, read as
  local time; else when it was added.
- **Stage**: new photos are `wip`. Mark as Completed and Mark as WIP change it
  for every selected photo.
- **Caption**: the first non-empty line of the notes. Without notes the photo
  shows its date taken.
- **Project photo**: one photo per project, shown small in the project's
  window title area, and nowhere else. Deleting that photo clears it.
- **Box notes**: drawn and numbered as on reference images.
- **Opening**: the image viewer, whose previous and next step through the
  project's build photos in grid order. Opening one of 2–4 selected photos
  compares them.
- **Export…**: asks for a folder and saves copies named
  `YYYY-MM-DD caption.ext` (date in local time; `/ : \ ? % * | " < >` and line
  breaks become spaces; at most 80 characters of caption), adding " 2", " 3"
  and so on rather than overwriting. **Remove location data** is on by default:
  the copy leaves out GPS metadata without re-compressing the pixels. The
  originals in the library are never changed.
- There's no moving or copying between References and Build Photos.

## Moving and copying references

- **Move to project**: the reference changes project and keeps everything.
- **Copy to project**: a new reference with a new id that keeps title, note,
  text, links, capture date, tags, video moments, link details and markups
  (new ids, same values and creation dates). It **shares** the original's asset,
  and its poster file is copied under the new reference id.
- Either way, a reference whose file the target project already has (same hash)
  is skipped and reported.

## Deleting

| Deleting | Also deletes | Never deletes |
|---|---|---|
| Project | its references, project paints, aftermarket items and build photos | kits (they stay in the catalogue, in no project, with their status), paints, tags |
| Reference | its tag links, video moments, markups and poster file | the asset, unless nothing else uses it |
| Build photo | its tag links and box notes; clears the project photo if it was that | the asset, unless nothing else uses it |
| Tag | its links | references, build photos |
| Paint | its ownership record, and a mix's recipe lines | — refused while any project paint or recipe uses it |
| Aftermarket item | — | its image asset, unless nothing else uses it |
| Kit | — | its picture asset, unless another copy or anything else uses it; projects (it leaves its project) |

- An asset is unused when no reference, aftermarket item, build photo or kit
  points to it.
  Deleting an unused asset deletes its original and thumbnail.
- Refusing to delete a paint names the projects using it, or the mixes:
  "*Tamiya XF-2 Flat White* is in the recipe for Custom Faded Sky Grey. Take
  it out of those mixes first."
- Deleting kits a project uses still asks once, and names the projects:
  "It's used by the project “Cobra”." Removing a kit from a project never
  deletes it, so it doesn't ask.
- Deleting a project first shows what goes with it, e.g. "12 references,
  3 image notes, 2 PDF markups, 8 paints from its paint list, 2 aftermarket
  parts and 5 build photos".

**Clean up** (in Settings) removes leftovers from interrupted work: unused
assets, files in `Originals` or `Thumbnails` with no asset, leftover partial
files, and posters with no reference.

## Sorting

Text sorts use "natural" order, which ignores case and compares runs of digits
as numbers, so XF-2 comes before XF-10 (Windows: `StrCmpLogicalW` or an
equivalent comparer).

- Projects in the sidebar: the user chooses Name (A to Z), Date Created
  (newest first) or Last Updated (most recent first). Projects with the same
  date are in name order. The choice is remembered, and starts as Name.
- References in a project: by capture date, newest first.
- Kits: by brand, name and number, then the order they were added, so copies
  stay together. Status sorts BNIB, Opened, WIP, Built, then kits that aren't
  owned. Ratings sort highest first; empty ratings and prices sort last.
- Paints: by brand, then code.
- Project paints: colours with no paint chosen first (by shown standard), then paints
  by brand and code.
- Aftermarket items: by status in the order listed in the format, then by name.
- Build photos: completed first, then work in progress; each newest taken
  first. Work in progress is grouped by day.

### When a project was last updated (stored)

A project's `updatedAt` is when the user last changed the project or anything
in it. Each save of the user's own edits sets it to now for every project
touched, which includes:

- editing the project's details or status, or choosing its project photo;
- adding, editing, moving, copying or deleting its references, build photos,
  notes, markups, paints or aftermarket items;
- adding a kit to it or removing one (moving a kit updates both projects);
- adding or removing tags on its references or build photos.

Moving a reference updates both projects.

Editing a kit, including a status change that follows the project, doesn't
change it by itself. These don't change it either: fetching link or video
details, suggested tags, and
changes to tags themselves (creating, renaming, colouring, merging or deleting
a tag). A new project's `updatedAt` equals its `createdAt`.

Code: `Services/ProjectActivity.swift` (`touchEditedProjects`).

## Search

One search field covers the whole library. It finds projects, kits, paints,
aftermarket items, references and build photos, with references and build
photos grouped by project ("F-16 — 3 references, 2 build photos").

- The query is split on whitespace. An item matches when **every** word is
  found in at least one of its fields.
- A word is found in a field when the folded field contains the folded word.
  Folding ignores case, accents and full-width forms. If that fails, both are
  compared with everything except letters and digits removed, so "f16" finds
  "F-16" and "xf54" finds "XF-54".
- Tags chosen as tokens in the field narrow the results to references and
  build photos with every chosen tag, and hide projects, kits, paints and
  aftermarket items. Choosing a tag in the sidebar shows the same results.

Fields searched:

| Item | Fields |
|---|---|
| Project | name, subject, its kits' brand, name, scale and number, markings, notes |
| Kit | brand, name, number, notes. Each copy is listed. |
| Paint | brand, range, code, name, standard, notes |
| Aftermarket item | product name, manufacturer, product number, type name, scale, notes, product page host |
| Reference | title (or the fallback title), kind name, tags, file name, source link, text, note, channel, site name, description, image note text, PDF markup text, video moment title and note |
| Build photo | caption, "Build Photo", stage name, tags, file name, the whole notes, box note text |

Each reference result lists the parts that matched, labelled ("Box 2",
"Highlight 3", "1:23", "Description"), with a short excerpt and the matched
words in bold. Results with a title match come first, then newest first.

A reference's fallback title, in order: its title; its file name; the first
line of its text (up to 120 characters); its source page's host; its kind name.

## Filters

In a project's gallery, the filter bar picks one kind and any number of tags.
A reference shows when it has the kind (if one is chosen) and **every** chosen
tag. Filters aren't saved.

The Paints screen filters by brand, range, type and Owned Only, together.
The Type menu lists All Types, each type that some paint has with its count,
then Not Set with its count. The paint picker has the same Type menu, without
counts. Filters aren't saved.

The sidebar can show projects of one status or all of them. That choice is
remembered, as is the sort order (see Sorting).

## Link details

When link details are turned on (the default), BenchBook fetches them for new
links, and for links that have never been fetched (the `…FetchedAt` field is
missing) when it opens. "Refresh" fetches again on request even when the
setting is off.

- A fetch that finds the item gone or private (an HTTP 4xx answer) records the
  attempt, so it isn't retried at every launch.
- A fetch that fails because the app is offline or the server has a problem (5xx)
  records nothing, so it's tried again next time.
- A fetched title replaces the stored one only if the stored one is missing, is
  a bare link or host, is "YouTube", or ends in " - YouTube" or " on Vimeo".
  It never replaces something the user typed.
- Every request has a 20-second timeout and sends `Accept-Language: en`.
- The poster or preview is saved to `Posters/<reference id>.jpg`. If no image
  downloads, any earlier one is kept.

### Video links

Recognised addresses:

- `youtu.be/<id>`
- `youtube.com`, `www.`, `m.`, `music.` and `www.youtube-nocookie.com`:
  `/watch?v=<id>`, or `/shorts/`, `/live/`, `/embed/`, `/v/` followed by `<id>`
- `vimeo.com`, `www.vimeo.com`, `player.vimeo.com`: the last all-digit path
  segment is the id

A YouTube id is 1–64 letters, digits, `-` or `_`.

The timestamp comes from the `t` or `start` query item, or a `#t=` fragment.
Accepted forms: `90`, `90s`, `1m30s`, `1h2m3s`, `1:30`, `1:02:03`.

To play at a moment: YouTube
`https://www.youtube.com/watch?v=<id>&t=<whole seconds>s`; Vimeo
`https://vimeo.com/<id>#t=<whole seconds>s`. Times show as `0:45`, `12:03` or
`1:02:03`.

**YouTube details**: oEmbed (`https://www.youtube.com/oembed?url=<watch url>&format=json`)
for title, channel and channel URL; then the watch page for length
(`"lengthSeconds":"N"`, else `<meta itemprop="duration">` as ISO 8601),
publish date (`<meta itemprop="datePublished">`, else `"publishDate"`),
description (`"shortDescription"`, cut to 5,000 characters) and any missing
title or channel. These requests send the cookie `CONSENT=YES+1`, which skips
the cookie-consent page in some regions. An oEmbed refusal isn't final, because
videos that can't be embedded still have a watch page. If neither gives a title
or a length, the video counts as not found. Poster: `i.ytimg.com/vi/<id>/maxresdefault.jpg`,
else `hqdefault.jpg`.

**Vimeo details**: oEmbed (`https://vimeo.com/api/oembed.json?url=https://vimeo.com/<id>&width=1280`)
for title, channel, length, upload date (`2013-10-15 14:08:29`, UTC) and poster.

BenchBook never downloads videos.

### Webpages

- Request the page with `Accept: text/html,application/xhtml+xml,*/*;q=0.8` and
  the honest `User-Agent: BenchBook (link preview)`. Sites that refuse automated
  requests just get no preview. Never get around a site's checks.
- If the response is an image, it's its own preview.
- Read only the first 1 MB, and only the part before `</head>`. Never run the
  page's scripts.
- **Limits**: stop reading a download at its limit rather than reading it all
  first: the page 1 MB, a preview image or icon 10 MB, a YouTube or Vimeo page
  or poster 5 MB. Requests time out after 20 seconds.
- **Public addresses only** for anything a website chose: follow a redirect
  only to an http(s) address on the public internet, and fetch preview images,
  icons and video posters only from one. Otherwise there's no preview. Not
  public: `localhost` and other names without a dot; names ending `.local`,
  `.localhost`, `.internal`, `.lan`, `.localdomain` or `.home.arpa`; private,
  loopback, link-local, carrier-grade NAT, multicast and reserved IP addresses
  (IPv4 and IPv6, including IPv4 written as IPv6); and numeric hosts in other
  forms (`127.1`, `2130706433`, `0x7f.0.0.1`). The link the user saved may
  itself be on their own network.
- **Title**: `og:title`, `twitter:title`, else `<title>`.
  **Site name**: `og:site_name`, `application-name`, `apple-mobile-web-app-title`.
  **Description**: `og:description`, `description`, `twitter:description`,
  with whitespace collapsed and cut to 2,000 characters.
- **Preview images**, tried in order: `og:image:secure_url`, `og:image`,
  `og:image:url`, `twitter:image`, `twitter:image:src`, `image`,
  `<link rel="image_src">`. Only http(s), resolved against the final address.
  An image must be at least 100 px on its shorter side. It's stored scaled to
  960 px at most on its longer side.
- **Icons**, used only when no preview image works: Apple touch icons first,
  then other `rel="icon"` links by size, then `/apple-touch-icon.png` and
  `/favicon.ico`. SVG icons are skipped. An icon must be at least 64 px, and
  it's stored at 192 px at most. Icons are shown at their own size, not
  stretched to fill a tile.
- Stored as JPEG at quality 0.82, or PNG when the image is transparent.

The aftermarket editor's "Use Image from Product Page" uses the same preview
image rules on the product URL, without falling back to icons, and stores the
result as the item's image asset.

## Kits

The Kits catalogue belongs to the library. Each entry is one physical kit, so
two boxes of the same kit are two entries. There's no quantity.

### Same kit (stored)

Two entries are the same kit when either:

- both links are Scalemates addresses and their keys match. The key is the
  host without `www.` plus the path, in lowercase, without a trailing slash
  or query: `https://www.scalemates.com/kits/Italeri-1234--100/?x=1` →
  `scalemates.com/kits/italeri-1234--100`; or
- brand, number and scale all match after folding: lowercase, with every
  whitespace character removed. The number must not be empty: without one,
  brand and scale alone would make every unnumbered kit of that brand and
  scale the same. Two empty scales match.

Owning the same kit twice is normal. Adding one by hand says "You already have
2 of this kit. This adds another." and still adds it. **Add Another Copy**
makes a new entry with the same brand, name, scale, number, link and picture,
owned and BNIB, with no price, rating, sale details or notes.

### Status and rating (stored)

- Status is `bnib`, `opened`, `wip` or `built`, shown as BNIB, Opened, WIP and
  Built. Unknown values show as BNIB and are kept until the user picks one.
- A kit that isn't owned shows "Not Owned" instead of its status, and the
  status can't be edited. The value is kept.
- Rating is a whole number from 1 to 5. Anything else reads as no rating.

### Prices (stored)

Prices are in the library's one currency, which isn't stored, and are shown in
the device's currency format. Typed or imported prices are read like this:

- Currency symbols, letters and spaces are ignored. A minus sign makes it
  unreadable.
- With both `.` and `,`, the last one is the decimal point.
- One separator used more than once groups thousands: `1,250,000`.
- One separator used once is the decimal point, unless it has one to three
  digits before it (not just `0`) and exactly three after: `1,250` is 1250,
  `0.250` is 0.25, `25,00` is 25.
- Files and backups write a plain number with a full stop and two decimals:
  `18.50`.

### Import

Reads a Scalemates stash export or BenchBook's own kits export. A file with a
`BenchBook ID` column is BenchBook's own. Columns are found by name, in any
order and case; other columns are ignored. Parsing is as for paint CSV.

| Column | Header names |
|---|---|
| ID | benchbook id |
| Brand (required) | brand, manufacturer |
| Name (required) | title, name |
| Scale | scale |
| Number | number, kit number |
| Type | type |
| Price Paid | price, price paid |
| Link | link, url |
| Owned, Status, Rating, For Sale, Sale Price, Notes | owned; status; rating; for sale; sale price; notes. Read from BenchBook files only. |

- **Only kits.** A row with a Type other than `Static model kits` (any case)
  is skipped and counted by its type. Rows with no Type are kits.
- A row without a brand or name is reported and skipped. A bad link or price
  is reported and left out; the rest of the row is imported.
- **Scalemates files.** Each row is one owned kit. Rows for the same kit are
  grouped. Rows and library entries with neither a number nor a Scalemates
  address are also the same kit when brand, name and scale fold the same.
  For each group:
  1. Owned entries for the kit count first, oldest first.
  2. If there are more rows than owned entries, entries that aren't owned
     become owned, oldest first.
  3. New entries are added for any rows left: owned, BNIB, no rating.
  4. Brand, name, scale, number and link are set from the group's first row
     on every matching entry. Empty values in the file never clear one.
  5. Rows are paired with entries in that order. A row's price fills its
     entry's Price Paid only if it has none. `0` means not entered.
  6. Status, rating, For Sale, Sale Price, notes and picture never change.

  Importing the same file again adds nothing, and import never deletes kits
  or lowers how many copies there are.
- **BenchBook files.** A row whose ID is in the library updates that entry;
  any other row is added, keeping its ID if it has one. Every column the file
  has is applied, except that an empty scale, number, link or price never
  clears one. Owned and For Sale
  are true for `yes`, `y`, `true`, `1`, `x`, `✓` or `✔`. Status must be BNIB,
  Opened, WIP or Built (any case); empty leaves it as it is, and BNIB for a new
  kit. Rating must be 1 to 5; empty means no rating. Other values are reported
  and that field is left as it was.
- The whole file saves at once: it all imports, or nothing does.
- The summary: "Added 3 Kits and Updated 1", then "Already in your catalogue:
  110.", "Skipped 27 rows for things other than kits: Markings (Decals) 22,
  Detail and Conversion sets 5.", and up to ten problems.

Test file: [fixtures/kits-scalemates.csv](fixtures/kits-scalemates.csv), a
made-up stash with two copies of one kit, two single kits and three rows that
aren't kits.

### Export

- Columns: `BenchBook ID,Brand,Title,Scale,Number,Type,Price,Link,Owned,Status,Rating,For Sale,Sale Price`,
  plus `Notes` only if the user asks.
- Type is always `Static model kits`. Owned and For Sale are `Yes` or empty.
  Status is BNIB, Opened, WIP or Built; an unknown stored status is written as
  it is.
- One row per entry, sorted by brand, number and scale, then the order they
  were added. Pictures aren't included.
- Quoting and line endings as for paint CSV. File name:
  `BenchBook Kits YYYY-MM-DD.csv`.
- Whether Scalemates can import this file is untested.

### Kits in projects (stored)

A project uses kits from the catalogue. A kit is in one project at most, since
each entry is one box.

- **Choosing**: Add from Kits… and the new-project sheet list only kits that
  aren't in a project. Move to Project (on the Kits screen) moves a kit from
  one project to another in one step. New Kit… adds a kit to the catalogue and
  the project. In the new-project sheet it's added to the catalogue straight
  away, even if the project is cancelled.
- **Removing** a kit from a project leaves it in the catalogue, in no project,
  with its status.
- **Summary**: the line under a project's name, in the sidebar and its window,
  is its one kit's brand and scale, or the number of kits, then its subject,
  skipping empty parts: "Italeri · 1:72 · AH-1W", "2 kits · Normandy".
- **Status follows the project**. Owned kits move forward, never back:

| What happens | Kit status |
|---|---|
| Project set to In Progress, or a kit added to an In Progress project | BNIB or Opened → WIP |
| Project set to Completed, or a kit added to a Completed project | anything but Built → Built |
| Researching or Paused | No change |

  Moving a project out of Completed leaves its kits Built. Kits that aren't
  owned don't change. An unknown stored status only changes for Completed.
  The user can set any kit's status by hand afterwards.
- **Needed**: a kit is needed when it isn't owned and its project isn't
  Completed. Needed kits are on the Shopping List.
- The Kits screen's Show filter adds **Not in a Project** and **Needed**.

### Upgrading from schema 3 (stored)

Projects used to have their own manufacturer, scale and kit number. The
upgrade to 4.0.0 adds whichever are filled in to the end of the project's
notes, after a blank line, e.g. `Kit: Italeri · 1234 · 1:72` (manufacturer,
number, scale; not localized). If that's already the last line, it isn't
added again. No kits are created: the user imports or adds their kits, then
adds them to projects. The library is copied first (`library-format.md` ›
The library on disk).

### Upgrading from schema 4 (stored)

Paint standards used to be free text, such as "FS 36270". The upgrade to
5.0.0 splits each paint's and each guide colour's text into a system and a
code, following Reading standard text. Rows that already have a system are
left alone, so running it again changes nothing. Match and type start as Not
Set. The library is copied first.

## Paint CSV

### Import

- Accepts quoted fields, `""` inside quotes, commas and line breaks inside
  quotes, and CRLF, LF or CR line endings. Blank lines are skipped.
- The first row names the columns, in any order and any case:

| Column | Header names |
|---|---|
| Brand (required) | brand, manufacturer, maker |
| Range | range, line, series |
| Code (required) | code, number, paint code, ref |
| Name | name, colour name, color name, paint name |
| Swatch | colour, color, hex, swatch, rgb |
| Owned | owned, own, have, in stock |
| Notes | notes, note, comments |
| Standard system | standard, when there's also a Standard Code column |
| Standard code | standard code |
| Match | match, standard match |
| Type | type, paint type |
| Standard, as written | fs/rlm, fs / rlm, standard (with no Standard Code column), colour standard, color standard, standards, equivalent |
| Standard, one system | fs, fs code, federal standard, fs595, fs 595 (FS); rlm, rlm code (RLM); bs, bs381c (BS); ral (RAL); ana (ANA) |

- **Standard and Standard Code** (BenchBook's own export): Standard names the
  system by its raw value, menu name or CSV name, ignoring case, or by a
  prefix such as `FS`. A name BenchBook doesn't know becomes Custom, with the
  name and code joined by a space ("Humbrol 28").
- **Otherwise**, standard columns are read as text: in a one-system column, a
  value starting with a digit gets the system's prefix (`36270` in an FS
  column becomes `FS 36270`), several columns are joined with ` / `, and the
  result is split following Reading standard text.
- Match accepts No match, Closest match, Exact match or the raw values,
  ignoring case, and is only kept when the paint has a standard. Type accepts
  the shown names, CSV names or raw values, ignoring case. Anything else is
  reported ("Line 7: “Gouache” isn't a paint type BenchBook knows, so no type
  was set.") and the paint is still added.
- Owned is true for `yes`, `y`, `true`, `1`, `x`, `✓` or `✔`, in any case.
- A bad swatch is reported ("Line 7: “bluish” isn't a colour like #4A5A6B, so
  no swatch was set.") and the paint is still added.
- A row without brand or code is reported and skipped.
- A row whose identity key is already in the catalogue, or earlier in the file,
  counts as a duplicate and is skipped.
- The whole file saves at once: it all imports, or nothing does.
- The summary gives the number added, the duplicates and the problems.

### Scalemates import

Import from Scalemates… reads a Scalemates paint stash export (Stash › Paints
› export, named like `SCM-PaintStash-20261122.csv`) and marks those paints
owned, adding any the catalogue doesn't have. It only adds: paints owned in
BenchBook but missing from the file stay owned. Example:
[fixtures/paints-scalemates.csv](fixtures/paints-scalemates.csv).

- The header must have `Color`, `Company` and `Number` (any case), or: "This
  isn't a Scalemates paint stash export." A header with no rows: "The file
  has no paints to import."
- **The header names ten columns, but each row has eleven values**: an
  unnamed column (`S` so far) sits between Remaining and Link. Named columns
  are read by their header position, and Link is the row's last value.
- Preview is `R;G;B` in 0–255, written as `#RRGGBB`. `;;` or empty is no
  colour. Anything else is reported ("Line 7: “10;20;300” isn't a colour
  like 168;181;155, so no swatch was set.") and the paint is still added.
- A row without Company or Number is reported ("Line 7: a paint needs a
  company and a number, so it was skipped.") and skipped.
- Condition, Remaining and the unnamed column are ignored.

**Company.** Scalemates puts brand and range together. BenchBook splits the
names it knows; any other company becomes the brand, with no range, and the
summary lists it. Matching ignores case and spacing.

| Company | Brand | Range | Type for "Acrylic" |
|---|---|---|---|
| Vallejo Model Air | Vallejo | Model Air | Water-based acrylic |
| Vallejo Model Color | Vallejo | Model Color | Water-based acrylic |
| Vallejo Metal Color | Vallejo | Metallic | Water-based acrylic |
| Vallejo Model Wash | Vallejo | Model Wash | Acrylic wash |
| Vallejo Game Air | Vallejo | Game Air | Water-based acrylic |
| Vallejo Mecha Colors | Vallejo | Mecha Color | Water-based acrylic |
| Vallejo Surface Primer | Vallejo | Surface Primer | Polyurethane-based paint |
| AK Real Colors | AK Interactive | Real Color | Not set |
| AK Interactive Air Series | AK Interactive | AIR | Water-based acrylic |
| AK Interactive | AK Interactive | | Not set |
| Mr. Aqueous Hobby Color | Mr. Hobby | Aqueous Hobby Color | Alcohol-compatible acrylic |
| Ammo by Mig Jimenez | Ammo by Mig | | Water-based acrylic |

**Type.** `Acrylic` is the table's type for the company (not set for one the
table doesn't know). `Acrylic Lacquer` and `Lacquer` are Lacquer, `Enamel` is
Enamel, `Pigments` is Pigment and `Oil` is Oil Paint. Anything else is read
as a [paint type](#paint-types) name, or not set.

**Matching the catalogue.** By brand and code, ignoring range, since
Scalemates' ranges don't line up with the catalogue's. The code is folded as
in the identity key, so `AK 480` matches `AK480`. Mixes are never matched.

- **One paint matches:** it's marked owned. Nothing else about it changes:
  not its name, range, swatch, type or notes. Already owned: counted, no
  change.
- **Several match** (the same brand and code in different ranges): the one
  whose range is the table's range. If none or more than one is, it's
  reported ("Line 7: AK Interactive AK 480 matches …, so none of them was
  marked owned.") and they're all left alone.
- **None matches:** a new paint, marked owned, with the brand, range, code,
  name (Color), swatch and type above. Its notes are Finish, Size and Link,
  joined with " · ": `Matt · 17ml · https://www.scalemates.com/colors/…`.
- Later rows for a paint already in the file (another bottle) are counted
  and skipped.
- The whole file saves at once: it all imports, or nothing does.

### Export

- Columns: `Brand,Range,Code,Name,Standard,Standard Code,Match,Type,Colour`,
  plus `Owned` (`yes` or empty) and `Notes` only if the user asks. Those two
  are personal, so they're off by default.
- Standard is the system's menu name (`FS 595`, `Multiple`), in English
  whatever the Mac's language. Match is `No match`, `Closest match` or `Exact
  match`, and Type is the type's CSV name. An unknown system, match or type is
  written as empty.
- Mixes are left out.
- Sorted by brand, range, then code. CRLF line endings.
- A field is quoted when it contains a comma, quote or line break, or starts or
  ends with a space. Quotes inside are doubled.
- File name: `BenchBook Paints YYYY-MM-DD.csv`.

## Shopping list

- **Kits**: needed kits (see Kits in projects), first, by project, then
  brand and name. Each shows its project. Ticking one as bought makes it
  owned and BNIB, and it leaves the list.
- **To buy**: paints that aren't owned and are needed by at least one project
  that isn't Completed: chosen for a colour, or in the recipe of a mix that's
  chosen. A mix itself is never listed. Grouped by brand (brands with the same folded name
  together, shown with the most common spelling), sorted by code. Each shows
  its projects, with what they're used for: "F-16C (upper surfaces), Spitfire".
  A paint needed for a mix adds "for" and the mix's name: "F-16C (upper
  surfaces, for Faded Sky Grey)", or "F-16C (for Faded Sky Grey)".
- **No paint chosen**: project colours with a standard but no paint, in
  projects that aren't Completed, by shown standard, then project.
- Ticking a paint as bought marks it owned, and it leaves the list.
- The sidebar badge counts paints to buy and needed kits.
- Saved as a plain-text checklist, `Paint Shopping List YYYY-MM-DD.txt`. With
  needed kits, the first line is "Shopping List" and the kits come first:

```text
Shopping List
13 November 2026 · 1 kit · 9 paints for 3 projects · 2 colours without paint

Kits
☐ Italeri Super Cobra · 1:72 · 1234
    Cobra

Tamiya
☐ XF-54 Dark Sea Grey · Acrylic XF · BS 640
    F-16C (upper surfaces), Spitfire

No Paint Chosen
☐ FS 36270
    F-16C (upper surfaces)
```

## Markups

### PDF markups

All sizes are in page points.

| | Value |
|---|---|
| Note width | 180 |
| Note padding | 8 |
| Note minimum height | 32 |
| Note text | 12 pt system font, black |
| Highlight stroke | 14 wide, round caps and joins, colour at 45% opacity, multiply blend |
| Arrow line | 3 wide, round caps; head 14 long, spread ±π/7, filled |
| Number badge | 18 across, filled with the markup's colour, 1.5 white outline, 10 pt bold digits (black on yellow and green, white otherwise) |
| Shortest stroke | 8; anything shorter is treated as a click |

- A new note is placed with its top-left corner at the click, moved to stay on
  the page. Its height grows to fit its text and keeps its top edge in place.
  Its fill is its colour blended 60% toward white, with a 1-point outline in the
  colour.
- A highlight's points are simplified by dropping any point closer than 1.5
  to the last kept one, always keeping the end. Its rectangle is the bounds of
  its points, grown by half the stroke width.
- An arrow stores two points, start and end. Its rectangle is their bounds,
  grown by half the head length.
- Moving a markup keeps it on the page, unless it's bigger than the page.
- The badge sits at a note's top-left corner, or at a stroke's first point.
  It's drawn moved inward just enough for the whole circle to be on the page
  (its centre at least 9 from every edge, or the page's centre on a page
  narrower than 18), in the viewer and in export. The stored points don't move.
- New markups use the last colour chosen for their kind. Defaults: notes and
  highlights yellow, arrows red.

Note heights depend on the font, so the same text can be a slightly different
height on each platform. That's fine. An app recalculates a note's height only
when its text is edited.

### Image notes

- Drawn by dragging a box on the image. Boxes under 8 × 8 image pixels are
  treated as a click. Boxes are kept inside the image.
- They can be moved and resized by their corners, and each has text.
- Stored as `note` markups in fractions of the image (see the format).

### Export marked-up copy

Saves a new PDF and never changes the original:

- Each page is drawn as it appears in the viewer (crop box and rotation), with
  its markups on top.
- Notes show their text on the page. Highlights and arrows that have text keep
  their number badge. Markups without text get no badge.
- If any highlight or arrow has text, a final "Markup Notes" section lists them:
  "3. Page 2 · Highlight", then the text. It's on pages the size of the last
  page, or US Letter if that's smaller, with 54-point margins, and runs over as
  many pages as it needs.

### Colours

Only names are stored. Each platform draws them with its own system colours.
These are approximate sRGB values for matching the Mac's light appearance:

| Name | Hex | | Name | Hex |
|---|---|---|---|---|
| red | `#FF3B30` | | mint | `#00C7BE` |
| orange | `#FF9500` | | teal | `#30B0C7` |
| yellow | `#FFCC00` | | indigo | `#5856D6` |
| green | `#34C759` | | purple | `#AF52DE` |
| blue | `#007AFF` | | brown | `#A2845E` |
| pink | `#FF2D55` | | gray | `#8E8E93` |

## Compare

Two to four selected images open side by side: in one row for two or three,
or a 2 × 2 grid for four. The user can switch between row and grid. Build
photos compare the same way, and can be dropped into a comparison next to
reference images.

## Settings

| Setting | Default |
|---|---|
| Fetch webpage previews and video details automatically | On |
| Suggest titles and notes for new images (Mac with Apple Intelligence only) | Off |
| Open images at fit to window, or actual size | Fit |
| Show note boxes when an image opens | On |
| Status for new projects | Researching |

On the Mac, Settings also has "Check for updates automatically" (see
[Updates](#updates)).

Settings also shows the library's location and space used, and has Clean Up,
Clear Thumbnails, Back Up, Restore, and a list of libraries kept from earlier
restores.

## Updates

Mac only. BenchBook › Check for Updates… looks for a newer version. If there
is one, a window shows its release notes with Install Update, Remind Me Later
and Skip This Version. Nothing is downloaded or installed until the user
chooses Install Update; BenchBook then relaunches as the new version.

On the second launch BenchBook asks whether to check for updates
automatically. If the user agrees, it checks once a day and shows the same
window when an update is found. Settings › General can turn this on or off
later, and has Check Now.

An update is installed only if it's signed with BenchBook's update key and
the list of versions is signed too. A check sends nothing but BenchBook's
version number.

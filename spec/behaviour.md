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
- "Remove unused tags" deletes tags with no links.
- Tags sort by how many references use them (most first), then by name.

### Paint identity (stored)

A paint's `identityKey` is `brand|range|code` after folding:

- brand and range: collapse whitespace, trim, lowercase.
- code: lowercase, then remove whitespace and the characters `- _ . /`.

So "Tamiya", "Acrylic XF", "XF-54" gives `tamiya|acrylic xf|xf54`, and
"XF 54" or "xf54" give the same key. A library holds one paint per key.
Creating or editing a paint whose key belongs to another paint is refused:
"*Tamiya XF-54 Dark Sea Grey* is already in your catalogue."

### Paint search

A paint matches a query when brand, range, code, name or standard contains it,
ignoring case. A standard also matches with spaces and punctuation removed from
both, so "FS 36270" finds "FS36270" and "FS-36270 / BS 637".

### Swatches

A swatch accepts `#RRGGBB`, `RRGGBB` or `#RGB`, and is stored as uppercase
`#RRGGBB`. Anything else isn't a colour.

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
   If saving fails, delete the copied file.
2. **Links**: http or https only, with a host. A YouTube or Vimeo address (see
   [Video links](#video-links)) becomes a `videoLink`, anything else a
   `webpage`. A video link with a timestamp also gets a moment at that time.
3. **Text**: trimmed, refused if empty, cut to 100,000 characters, saved as a
   `textSnippet` with its source page if known.

A capture can carry tags and a note, which apply to every item in it. A batch
reports failures and duplicates in one message at the end. Successful items stay
saved even when others fail.

After a link is saved, its details are fetched in the background (see
[Link details](#link-details)). Saving never waits for the network.

The same file in two projects is two references with two assets. Only copying
a reference shares an asset.

### Notes

A note is a reference of kind `note` that the user writes in BenchBook. It
needs a title or some text ("Write a title or some text for the note."). Its
body keeps line breaks and indentation, trimmed only at the ends.

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
| Project | its references, project paints and aftermarket items | paints, tags |
| Reference | its tag links, video moments, markups and poster file | the asset, unless nothing else uses it |
| Tag | its links | references |
| Paint | its ownership record | — refused while any project paint uses it |
| Aftermarket item | — | its image asset, unless nothing else uses it |

- An asset is unused when no reference and no aftermarket item points to it.
  Deleting an unused asset deletes its original and thumbnail.
- Refusing to delete a paint names the projects using it.
- Deleting a project first shows what goes with it, e.g. "12 references,
  3 image notes, 2 PDF markups, 8 paints from its paint list and 2 aftermarket
  parts".

**Clean up** (in Settings) removes leftovers from interrupted work: unused
assets, files in `Originals` or `Thumbnails` with no asset, leftover partial
files, and posters with no reference.

## Sorting

Text sorts use "natural" order, which ignores case and compares runs of digits
as numbers, so XF-2 comes before XF-10 (Windows: `StrCmpLogicalW` or an
equivalent comparer).

- Projects: by name.
- References in a project: by capture date, newest first.
- Paints: by brand, then code.
- Project paints: colours with no paint chosen first (by standard), then paints
  by brand and code.
- Aftermarket items: by status in the order listed in the format, then by name.

## Search

One search field covers the whole library. It finds projects, paints,
aftermarket items and references, with references grouped by project.

- The query is split on whitespace. An item matches when **every** word is
  found in at least one of its fields.
- A word is found in a field when the folded field contains the folded word.
  Folding ignores case, accents and full-width forms. If that fails, both are
  compared with everything except letters and digits removed, so "f16" finds
  "F-16" and "xf54" finds "XF-54".
- Tags chosen as tokens in the field narrow the results to references with
  every chosen tag, and hide projects, paints and aftermarket items.

Fields searched:

| Item | Fields |
|---|---|
| Project | name, manufacturer, subject, scale, kit number, markings, notes |
| Paint | brand, range, code, name, standard, notes |
| Aftermarket item | product name, manufacturer, product number, type name, scale, notes, product page host |
| Reference | title (or the fallback title), kind name, tags, file name, source link, text, note, channel, site name, description, image note text, PDF markup text, video moment title and note |

Each reference result lists the parts that matched, labelled ("Box 2",
"Highlight 3", "1:23", "Description"), with a short excerpt and the matched
words in bold. Results with a title match come first, then newest first.

A reference's fallback title, in order: its title; its file name; the first
line of its text (up to 120 characters); its source page's host; its kind name.

## Filters

In a project's gallery, the filter bar picks one kind and any number of tags.
A reference shows when it has the kind (if one is chosen) and **every** chosen
tag. Filters aren't saved.

The sidebar can show projects of one status or all of them. That choice is
remembered.

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
| Standard, as written | fs/rlm, fs / rlm, standard, colour standard, color standard, standards, equivalent |
| Standard, one system | fs, fs code, federal standard, fs595, fs 595 (FS); rlm, rlm code (RLM); bs, bs381c (BS); ral (RAL); ana (ANA) |

- In a one-system column, a value starting with a digit gets the system's
  prefix: `36270` in an FS column becomes `FS 36270`. Several standard columns
  are joined with ` / `.
- Owned is true for `yes`, `y`, `true`, `1`, `x`, `✓` or `✔`, in any case.
- A bad swatch is reported ("Line 7: “bluish” isn't a colour like #4A5A6B, so
  no swatch was set.") and the paint is still added.
- A row without brand or code is reported and skipped.
- A row whose identity key is already in the catalogue, or earlier in the file,
  counts as a duplicate and is skipped.
- The whole file saves at once: it all imports, or nothing does.
- The summary gives the number added, the duplicates and the problems.

### Export

- Columns: `Brand,Range,Code,Name,FS/RLM,Colour`, plus `Owned` (`yes` or empty)
  and `Notes` only if the user asks. Those two are personal, so they're off by
  default.
- Sorted by brand, range, then code. CRLF line endings.
- A field is quoted when it contains a comma, quote or line break, or starts or
  ends with a space. Quotes inside are doubled.
- File name: `BenchBook Paints YYYY-MM-DD.csv`.

## Shopping list

- **To buy**: paints that aren't owned and are chosen in at least one project
  that isn't Completed. Grouped by brand (brands with the same folded name
  together, shown with the most common spelling), sorted by code. Each shows
  its projects, with what they're used for: "F-16C (upper surfaces), Spitfire".
- **No paint chosen**: project colours with a standard but no paint, in
  projects that aren't Completed, by standard, then project.
- Ticking a paint as bought marks it owned, and it leaves the list.
- Saved as a plain-text checklist, `Paint Shopping List YYYY-MM-DD.txt`:

```text
Paint Shopping List
13 November 2026 · 9 paints for 3 projects · 2 colours without paint

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
or a 2 × 2 grid for four. The user can switch between row and grid.

## Settings

| Setting | Default |
|---|---|
| Fetch webpage previews and video details automatically | On |
| Suggest titles and notes for new images (Mac with Apple Intelligence only) | Off |
| Open images at fit to window, or actual size | Fit |
| Show note boxes when an image opens | On |
| Status for new projects | Researching |

Settings also shows the library's location and space used, and has Clean Up,
Clear Thumbnails, Back Up, Restore, and a list of libraries kept from earlier
restores.

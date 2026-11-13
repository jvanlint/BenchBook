# BenchBook spec

This folder describes BenchBook precisely enough to build another version of
it, starting with Windows, without reading the Mac source.

The Mac app is the reference. Where the spec and the Mac app disagree, the Mac
app is right and the spec is out of date. Any change to the Mac data model,
backup format or the rules in `behaviour.md` updates this folder in the same
commit.

| File | What it covers |
|---|---|
| [library-format.md](library-format.md) | The portable library and backup format both apps read and write. This is the contract between them. |
| [behaviour.md](behaviour.md) | The rules every BenchBook follows: names and duplicates, file checks, deleting, search, link details, paint CSV, markup geometry. |
| [windows-app.md](windows-app.md) | How the Windows app is built: technology, screens, what maps to what, phases, and decisions still to make. |
| [screens.md](screens.md) | Every screen: what it shows, what it does and what it says, with screenshots in [screens/](screens/). |
| [windows-handoff.md](windows-handoff.md) | Start here. The brief for whoever builds the Windows app, with the working rules. Copy it into the Windows project as `CLAUDE.md`. |

## Terms

- **Library**: everything a user has saved: the records plus the files they refer to.
- **Project**: one intended build, such as a Tamiya 1:48 F-16CJ.
- **Reference**: one saved item in a project: an image, PDF, Markdown file, webpage, video link, text snippet or note.
- **Asset**: a file the library keeps a private copy of (images, PDFs, Markdown).
- **Poster**: a video's poster image or a webpage's preview image, fetched from the web.
- **Markup**: a note, highlight or arrow on a PDF page, or a note box on an image.
- **Paint**: a commercial paint in the catalogue, such as Tamiya XF-54 Dark Sea Grey.
- **Project paint**: a colour a project needs, and the paint chosen for it.
- **Aftermarket item**: a part bought or considered for a project, such as decals or a resin cockpit.

## Versions

- Data model: schema **1.0.0**, as shipped in BenchBook 1.0.0.
- Portable backup: format **2** (proposed here). The Mac app's current backups are format 1, which only a Mac can read.

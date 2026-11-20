# Changes since BenchBook 1.0

What the Mac app has gained since 1.0, newest first, so the Windows app can
catch up. Each entry says where the spec describes it. When a Windows change
brings one across, note it in the Windows project, not here.

The spec sections are the reference. This list is only a checklist.

| Change | Issue | Format change | Spec |
|---|---|---|---|
| Clear paints (any paint with "clear" in its name) are drawn as glass, not flat white or colour. | #42 | No | behaviour.md › Swatches; screens.md › Paint editor |
| Projects use kits from the catalogue: a Kits tab in each project (⌘1, so the other tabs move to ⌘2–⌘5), kits chosen in the new-project sheet, Move to Project, status following the project, needed kits on the Shopping List, and a Project column and Not in a Project and Needed filters on the Kits screen. Project manufacturer, scale and kit number are removed; the upgrade adds them to the notes. The library is copied before an upgrade. | #44 | Yes: schema 4.0.0, `kits.projectId`; `projects.manufacturer`, `scale` and `kitNumber` removed | library-format.md › projects, kits, The library on disk, Compatibility; behaviour.md › Kits in projects, Upgrading from schema 3, Shopping list, Deleting; screens.md › Project Kits tab, Project editor, Kits catalogue, Shopping list |
| Kits catalogue: one entry per physical kit, with status, rating, prices, box art, Scalemates and BenchBook CSV import and export, and search. | #41 | Yes: schema 3.0.0, `kits`, and the `decimal` value type | library-format.md › kits; behaviour.md › Kits; screens.md › Kits catalogue, Kit editor |
| The aftermarket editor's picture well is shared with the kit editor. No change for the user. | #41 | No | screens.md › Aftermarket editor |
| Sort projects in the sidebar by Name, Date Created or Last Updated. The choice is remembered. | – | No | behaviour.md › Sorting; screens.md › Sidebar |
| A project's last updated date now changes whenever the user changes anything in the project, not only its details. | – | No, but the rule is **(stored)** | behaviour.md › When a project was last updated |
| Build Photos: the user's own photos of a build, with WIP and Completed stages, notes, tags, box notes, a project photo in the header, and export without location data. | #43 | Yes: schema 2.0.0, `buildPhotos`, `buildPhotoTags`, `projects.projectPhotoId`, `markups.buildPhotoId` | library-format.md; behaviour.md › Build photos; screens.md › Build Photos |
| Build Photos: select by dragging a rectangle, as in References. Delete works on a rectangle selection. | #43 | No | screens.md › Build Photos |

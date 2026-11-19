# Changes since BenchBook 1.0

What the Mac app has gained since 1.0, newest first, so the Windows app can
catch up. Each entry says where the spec describes it. When a Windows change
brings one across, note it in the Windows project, not here.

The spec sections are the reference. This list is only a checklist.

| Change | Issue | Format change | Spec |
|---|---|---|---|
| Sort projects in the sidebar by Name, Date Created or Last Updated. The choice is remembered. | – | No | behaviour.md › Sorting; screens.md › Sidebar |
| A project's last updated date now changes whenever the user changes anything in the project, not only its details. | – | No, but the rule is **(stored)** | behaviour.md › When a project was last updated |
| Build Photos: the user's own photos of a build, with WIP and Completed stages, notes, tags, box notes, a project photo in the header, and export without location data. | #43 | Yes: schema 2.0.0, `buildPhotos`, `buildPhotoTags`, `projects.projectPhotoId`, `markups.buildPhotoId` | library-format.md; behaviour.md › Build photos; screens.md › Build Photos |
| Build Photos: select by dragging a rectangle, as in References. Delete works on a rectangle selection. | #43 | No | screens.md › Build Photos |

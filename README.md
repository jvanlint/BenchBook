# BenchBook

A native macOS app for gathering and using scale-modelling research, organised by build Project. The product references are in [`docs/`](docs/): requirements, data model, macOS architecture and implementation plan.

## Current scope

This is Phase 0–1 of [`docs/implementation-plan.md`](docs/implementation-plan.md):

- Project sidebar with Add Project.
- A sheet for creating and editing a Project: name (required, nonblank), manufacturer, subject, scale, kit number, markings scheme and notes.
- Local SwiftData persistence.
- A Project workspace with References, Paint and Aftermarket sections. References opens first. Each section shows an empty state for now.
- Empty states for an empty library and for no selection.

Deferred until agreed or scheduled: Project status, cover, all other models, capture, import, viewing, paint, aftermarket entry and sync.

## Requirements

| | |
|---|---|
| Deployment target | **macOS 15.0** |
| Built with | Xcode 27, Swift 5 language mode, default MainActor isolation |
| Dependencies | None |

Why macOS 15: everything used now (SwiftData, `VersionedSchema`, `ContentUnavailableView`, `NavigationSplitView`, `@Entry`) also runs on macOS 14. macOS 15 adds SwiftData's `#Index` and `#Unique` macros, which the data-model guide expects to evaluate for reference queries and identity rules, and includes SwiftData fixes released after its first version. Lowering the target to 14.0 later is possible, as long as those macros aren't adopted.

## Layout

```text
BenchBook/
  App/        App entry point and menu commands
  Models/     Versioned SwiftData schema (BenchBookSchemaV1) and display helpers
  Services/   PersistenceController (store setup), ProjectService (validation and saves)
  Views/      Sidebar, workspace, project editor
BenchBookTests/  Swift Testing unit tests for ProjectService and persistence
```

Rules:

- Views edit a `ProjectDraft` and hand it to `ProjectService`. The service validates the draft, normalises blank optional text to `nil`, updates `updatedAt` and saves explicitly.
- The schema is versioned from the start (`BenchBookSchemaV1` and `BenchBookMigrationPlan`). Add a new `VersionedSchema` and migration stage for model changes instead of editing V1 after release.
- If the store fails to open, the app shows an error and leaves the store alone. It never deletes or resets it.

The library is stored at `~/Library/Containers/com.jasonvanlint.BenchBook/Data/Library/Application Support/BenchBook.store`.

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘N | New Project |
| ⌘I | Edit selected Project |
| ⌘1 / ⌘2 / ⌘3 | References / Paint / Aftermarket |
| ⌃⌘S | Show or hide sidebar |

## Testing

```sh
xcodebuild -project BenchBook.xcodeproj -scheme BenchBook -destination 'platform=macOS' test
```

To try the app without touching your real library, launch a Debug build with a separate store:

```sh
open BenchBook.app --args -BenchBookStoreName BenchBookScratch
```

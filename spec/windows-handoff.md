# Start here: building BenchBook for Windows

This is the brief for whoever builds the Windows app, including a Claude Code
session on a Windows PC. Copy it into the Windows project as `CLAUDE.md`, and
keep it up to date there.

## What BenchBook is

A private reference library for scale modellers. Each build is a project, and
the user saves photos, PDFs (kit instructions), links, videos, highlighted text
and notes to it, then uses them at the bench. It also tracks paints (with a
shopping list) and aftermarket parts. Everything stays on the user's computer.

BenchBook for Mac 1.0 is released. Its code is public at
https://github.com/jvanlint/BenchBook. The Windows app is a separate, native app
that reads and writes the same backups.

## Read these first, in order

1. `spec/README.md`: what the spec covers, and the terms it uses.
2. `spec/windows-app.md`: the plan: technology, screens, phases, open decisions.
3. `spec/library-format.md`: the backup format. It's the contract with the Mac
   app, so follow it exactly.
4. `spec/behaviour.md`: the rules. The ones marked **(stored)** must give
   exactly the same results as the Mac.
5. `spec/screens.md` and `spec/screens/`: every screen and its wording.

If the spec doesn't answer a question, read the Swift code it points to. If
the code and the spec disagree, the code is right: say so, so the spec gets
fixed. Don't guess.

## Before writing Windows code

Phase 1 happens on the Mac: the Mac app writes and reads format 2 backups,
and a sample backup is added under `spec/fixtures/`. Check that it's done
before building backup or restore, because the Windows tests rely on that
sample.

Then decide the open questions in `windows-app.md` with the user, starting with
the PDF library and the repository.

## Working rules

These are the user's rules for the Mac app, and they apply here too.

**Git**

- One branch per issue or feature, named `issue-N-short-name`.
- Commit or merge only when asked. "Commit this" means commit on the branch.
  "Commit to main" means: commit on the branch, `git merge --ff-only` into
  main, delete the branch, and push main. No pull requests.
- Commit messages say what changed for the user, and end with "Fixes #N" when
  there's an issue.

**Code**

- Native Windows controls, system fonts, system colours and Fluent icons.
  Nothing custom-drawn where a standard control exists.
- No new dependency (NuGet package, native library or tool) without
  discussing it with the user first, including why the built-in option isn't
  enough.
- Don't add sample records to the user's library. Tests use their own temporary
  libraries.
- Never delete or recreate the user's store or files to recover from an error.
  Report the error and leave the data as it is.
- Keep the user's original files byte-for-byte.
- Write in British English ("colour"), in short, plain sentences, as the Mac
  app does.

**Honesty**

- When a check can't be run, such as a build, a test or trying something on a
  real device, say so plainly. Don't report it as done.
- Report test failures as they are.

**Privacy and the web**

- No telemetry, analytics, accounts or cloud services.
- Web requests only fetch link details, as `behaviour.md` describes. The
  User-Agent stays the honest `BenchBook (link preview)`. Never get around a
  site's bot checks.
- Don't send the user's email address or other personal details to any
  service.
- Signing certificates and Store credentials are handled by the user only.
  Never ask for them, store them, or put them on a command line.

**Testing with the user**

- Run builds and unit tests yourself.
- The user tries the UI themselves. Don't drive the app with synthetic clicks
  or keystrokes.
- Screenshots: capture only BenchBook's own window, never the whole screen.

## When the Mac app changes

The Mac app is the reference. If a change on the Mac affects the format or the
rules, its commit updates `spec/`. Check `git log -- spec/` in the Mac repo for
changes since the last time you looked.

# 2026-11-19 "Quit Anyway" for one document also gave up another document opened in the same project

## Symptom

Found by code review CXR3 (R1, P1), not reported by a user. Quit with two projects open, the main window's project A on a
drive that does not answer:

1. After 3 s the alert says "“A” isn't saved yet"; the person chooses **Quit Anyway** (giving up A's unsaved changes).
2. Quit goes on to a second project whose drive is slow too, and asks about it.
3. Meanwhile A's write lands, and an Open that was waiting for it (Open Recent pressed before Quit; the AI's
   `open_project` running inside the alert's modal loop) replaces A with project B **in the same main window project**.
4. An AI tool call edits B.

Quit's last look skipped the main window project, said yes, and SkyCut quit with B's edit unsaved. Nobody had chosen to give
up anything in B: the alert only ever showed A.

## Root cause

`ProjectQuit.prepareEach` kept what it decided per project **object** (`marks[ObjectIdentifier(project)]`), and `.gaveUp`
meant "never look at this object again". But a project object holds documents one after another: New and Open replace the
document in place (`closeCurrentDocument`, a new `documentGeneration`). "Quit Anyway" is a decision about the document the
alert showed, not about the object that held it.

The other mark, `.letThrough`, already carried the document generation (`QuitMark.Snapshot`), so a project let through and
replaced since was settled again; `.gaveUp` carried nothing. The two-project check added with
[the previous Quit fix](2026-11-19-close-trusts-a-stale-save.md) only exercised a project that was let through, never one
given up.

The same object-keyed mark had a second, rarer way in: when a project is closed and freed during Quit (the AI's
`close_project` while an alert is up), a project opened afterwards can get the same `ObjectIdentifier` and inherit the old
mark. The document generation comes from one App-wide counter (`DocumentGenerations`) and is never reused.

## Fix

- **`ProjectQuit.settle`** takes `project.documentGeneration` right before asking (the document the alert shows) and returns
  `.gaveUp(generation)` for "Quit Anyway".
- **`ProjectQuit.needsSettling`**: a project given up is settled only while it still holds that generation; another
  document opened in it since is settled like any other — written, or asked about with its own alert.
- Rule: [project file](../architecture/video-edit-project-file.md) §5 "Writing the project file off the main thread" item 6.

## Verification

- `scripts/check-project-saves.sh`, new `EditWhileClosingChecks.quitAnywayThenReplaced`, on the real main window project:
  A's drive is held and the check answers "Quit Anyway"; inside the second project's question it lets A's write land, opens
  B into the same project with `openProject(at:)`, edits B and cancels the autosave (SkyCut is gone at the reply); then the
  second project's write lands. Required: Quit says yes, both projects were asked about, and B's file holds the edit.
  The check now has 64 assertions (3 new), all green.
- Reverse verification: the new check was written first and run on the code before the fix (`.gaveUp` without the
  generation) → 64 assertions, exactly 1 red: "a document opened in the same project since is written before Quit says
  yes" (the setup assertion — Quit said yes, both projects were asked, B was open in the main window project — was green).
  With the fix → 0 red.
- `checks/open-projects-wiring.sh` pins that a given-up project is settled again when its document generation changed:
  red on the code before the fix, green with it.
- Not verified: the real Quit alert with a real slow drive (manual items in video-edit-project-file.md §7, item 3).

## Lessons

- A decision a person makes about what an alert showed belongs to that document, not to the object that held it: store
  the document generation with the decision and compare it before the decision is applied again.
- A mark keyed by object identity outlives what it was about: the object can hold another document, and a freed object's
  identifier can be reused. Every mark Quit keeps now carries the generation.

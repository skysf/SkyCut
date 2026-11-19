# 2026-11-19 The export panel checked one folder and replaced a file in another

## Symptom

Not reported by a user: review CXR2, finding R4 (P1).

The export folder is A, which has no file named like the export. The user drops folder B onto "Export to" — B already
holds a film with that name — and presses Export while B is still being checked (a slow drive; the Export button stays
enabled while a dropped folder is checked). B's check passes and B becomes the destination; then the check of A that the
Export button started comes back. The panel decided "no file of that name, no question" from A's listing, but started the
export into the folder shown at that moment, B: the finished video replaced B's film without asking.

The same could happen the other way round (Export pressed first, a folder dropped while A was being checked), and the
replace question read the folder and name live, so it could name one file while Replace wrote another.

## Root cause

1. `ExportDestinationState.checkBeforeWriting()` checked the folder that was the destination when it started, and
   returned that report even when the destination had changed while it was out (the "same folder?" test only decided
   whether the row's status was updated).
2. `VideoEditExportSheet.requestExport()` decided from that report but `startExport()` read `outputURL` again — the
   folder shown now. Three different moments decided the file that was checked, the one the question named and the one
   that was written.
3. A folder being taken (`use`) did not hold back the check before writing: `isTaking` only disabled the folder controls.
4. Every panel export was delivered with replace semantics, so an export the user was never asked about could still
   replace a file.

## Fix

- `ExportDestinationState.checkBeforeWriting()` waits until no folder is being taken or looked up (`use`, `resolve`), and
  drops a check that comes back for a folder that is no longer the destination, checking the destination again; its answer
  names the folder (`WriteCheck`).
- `exportDecision(stem:pathExtension:)` decides pressing Export from that answer: `.refused`, `.askToReplace(file)` or
  `.export(.newFile(...))`. The sheet keeps the file of `.askToReplace` for the question and Replace writes exactly it
  (`.replacing(file)`); an export nobody was asked about is a new file, so a file that appears during the export is never
  replaced (it gets a number: ExclusivePlacement, [case](2026-11-19-parallel-ai-exports-pick-the-same-name.md)).
- The panel's subtitle files do the same: the files checked, named in the question and written are fixed when the check
  comes back.
- Rules: [export settings](../architecture/export-settings.md) §5 item 7 and §8 item 5.

## Verification

- `scripts/check-export-profile.sh`, new `PanelTargetChecks` (145 assertions green; real folders, a file system whose A
  answers in 0.6 s and B in 0.2 s, real exports):
  - B being taken when Export is pressed: the decision asks about B's file, and B's file is unchanged;
  - Export pressed first, B taken while A's check is out (A comes back last): A's check is dropped, B is asked about;
    nothing written into A or over B's file;
  - Replace writes exactly the file the question named;
  - an empty folder at the check, a file appears during the export: a new file (`Clip 2.mp4`), the other file untouched.
- Reverse verification (each went red, then green after restoring):
  - the old logic (the check returns the first folder's report, the export goes into the folder shown now, every panel
    export replaces) → 5 red: B's film replaced in both orders, and the file that appeared during the export replaced;
  - only the folder pinning taken out (new files still never replace) → 3 red: both decisions export instead of asking
    about B's file, so there was no question and no Replace (B's film survived only because a new file no longer
    replaces anything).
- Scan guard `checks/file-io-off-main-wiring.sh`: the sheet decides through `exportDecision`, which decides from
  `checkBeforeWriting`, and never exports to `outputURL` (red when the sheet exports to `.replacing(outputURL)` again).
- Not verified: the real panel window with a real drag (manual regression item 19 in
  [export settings](../architecture/export-settings.md)).

## Lessons

- An async check returns an answer about one thing; carry what it was about with the answer, and act on exactly that.
- A confirmation must name, and the action must write, the same value that was checked: pin it in the request.

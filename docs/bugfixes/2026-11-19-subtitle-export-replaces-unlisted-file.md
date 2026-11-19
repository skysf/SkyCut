# 2026-11-19 The export panel's subtitle files could replace a file the replace question never listed

## Symptom

Not reported by a user: review CXR3, finding R4 (P1).

In the export panel's "Export Subtitle Files" (under Advanced), check Original SRT and Translated VTT when only the SRT is in
the export folder. The panel asks "Replace “Talk.en.srt”?". If another export creates `Talk.zh-Hans.vtt` while that question
is open, answering Replace also replaces the VTT, which the question never named. The same happens with no question at
all: the check's listing comes back without a file that appears before the write, and the write replaces it.

## Root cause

The question listed only the files the check found (`replaceQuestion`), but the write loop sent **every** file through the
replacing write (`SubtitleExportPlanner.writeValidated(_:format:to:)`). Answering Replace was treated as consent for the
whole set rather than for the files it named, and an export with no question at all was treated the same way. The
earlier fix ([the panel checks one folder and writes another](2026-11-19-export-panel-checks-one-folder-writes-another.md))
froze the folder and the set of files, but not one decision per file.

## Fix

- `SubtitleFilesWrite` (new) holds the button's work, apart from the view. The press (`request`) runs the check before
  writing, takes the files in the checked folder and asks about the ones that check found. Replace (`replace`) replaces
  exactly the files the question named. Every other file is written as a new file through the new
  `SubtitleExportPlanner.writeNew`: the same temporary name and read-back, then the name taken in one step that fails when
  it is taken ([export settings](../architecture/export-settings.md) §5 item 9). A file the question did not list is left as
  it was, and the panel says so in the system's words; pressing the button again asks about it. The writes stay off the
  main thread.
- `SubtitleFilesExport` (the view) keeps the checkboxes, the names, the hint and the question's wording. It reads the
  question, the written files and the error from the model, and its alert's Replace calls `replace`.
- Rule: [export settings](../architecture/export-settings.md) §5 item 7.

## Verification

- `scripts/check-export-profile.sh`, new `SubtitlePanelChecks` (through `request` and `replace`, the calls the button and the
  alert make, on real folders):
  - **the review's sequence**: the question names only the SRT, the VTT appears while it is open, Replace replaces the SRT,
    the VTT keeps its bytes and the panel names it;
  - a listing that came back without a file that is there at the write: nothing asked, nothing replaced, the other file
    written;
  - nothing there: both written, nothing said.

  186 assertions green. `SrtFlowCoreChecks`: `writeNew` makes a free name and leaves a taken one.
- Reverse verification: the model's loop replacing every file again (the old behaviour) → 3 red (the VTT replaced, nothing
  said, the stale-listing file replaced); green after restoring.
- `checks/file-io-off-main-wiring.sh` (new lines: replacing only a named file, `writeNew` for the rest, Replace with the
  question's set, no write in the view, no `FileManager` in the model) → red with the model replacing every file.
- Not verified: the real sheet clicked by hand (the alert and checkboxes are SwiftUI; the check drives the model they call).

## Lessons

- A confirmation covers the items it named. Carry the decision per item through to the write, and give everything else the
  write that never replaces.
- The gap between asking and writing is where other writers act. Test a file arriving while the question is open, and a
  check whose listing is already stale.

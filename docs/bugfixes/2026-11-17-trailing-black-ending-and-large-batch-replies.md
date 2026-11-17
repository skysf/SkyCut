# 2026-11-17 A black ending needed a placeholder and large edit batches repeated full summaries

## Symptom

MCP-17 could not retain a 141-second project ending after its last picture ended at 139.08 seconds without adding a placeholder.
There was no explicit project duration parameter: the timeline always ended with its content. A batch of 76 ordinary clip edits
also returned every detailed single-clip summary, including repeated file names and picture transforms, making the reply hard to
consume. The acceptance case requires fewer than 2,000 JSON characters for that simple batch.

## Root cause

`TimelineState.duration` computed only the maximum content end; no persisted value could retain a later ending. `set_canvas`
accepted only ratio and fps. `edit_clips` reused the detailed single-edit results with no optional projection for ordinary
successful entries. Hiding all result details would have lost important clamps, warnings and actual destinations.
The old canvas route also opened an undo group before validation; failed or repeated duration requests therefore left an empty
undo step even when no state changed.

## Fix

`TimelineDuration` preserves the existing content-end rules and takes the maximum with a saved `minimumDuration`. `set_canvas`
accepts `duration`: a positive value must cover current content and one frame; zero clears it. All arguments validate before
any write, and a local undo group opens only for a real state change and covers the whole call. Repeating a ratio still preserves
its recording-import intent marker without an empty undo step. The normal preview/export black-base paths and audio clock
consume the same duration, without creating a clip. Format v37 protects this optional value from older writers. Selected-only
exports exclude the project-wide ending; black-only projects can export video, including a tiny manually saved ending.
The integration keeps web-motion source at its already merged v36 gate and registers the ending separately at v37; the
reader's future-version refusal is v38. Both model companions remain in every standalone check source list.

`edit_clips compact=true` returns input-order ids and exception notices derived from final single-edit summaries. It preserves
requested/applied adjustments, warnings, source-cut findings, requested fills that remain uncovered, explicit region framing,
track destinations and replacement windows, as well as batch-level linkage/magnet feedback. The default remains detailed.
The compact option changes only the reply and is validated before asynchronous preparation.

## Verification

- Against the pre-fix production paths, the new application check failed on the missing duration/compact schemas and rejected
  duration-only / compact calls (4 failures in 48 assertions). No private media or installed application was used.
- The first full production run measured 873 JSON characters for the 76-entry compact reply versus 28,275 for the detailed
  reply. It exposed three empty-undo failures on repeated/invalid duration requests; grouping now follows validation.
- `scripts/check-project-file.sh` covers optional old-file defaults, round-trip persistence, literal v37 protection, clearing,
  later content and selected-export isolation.
- `scripts/check-parameter-limits.sh` exercises the real tools, one undo/redo, all-or-nothing rejection, saved-version and audio
  duration flow, 76 actual edits, final-value notices, and native preview plus FFmpeg export of black endings and black-only video.
- `scripts/check-mcp.sh` covers the compact projection, bounded ordinary replies, duplicate ids, exceptions and schemas. Its
  wiring scans require the compact result projection and the saved duration commit/read paths.
- Reverse verification restored content-only duration and detailed-only batch replies: the project-file check failed 3 of
  1,341 assertions, and the App check failed 12 of 73 reached assertions. The compact reply grew back to 28,275 characters;
  duration, audio/preview end and final-value notice assertions failed. Separately, restoring the old router wrapper or removing
  the local commit group made their wiring scans exit 1 under the parent entry's `-euo pipefail` options. All modified
  production files were restored byte for byte before the positive rerun.
- After restoration, `scripts/check-local.sh project-file parameter-limits sky-studio` passed all scans, 1,341 project-file
  assertions, 143 App assertions and 7,738 Sky Studio assertions. The compact reply returned to 873 characters. The MCP suite
  also passed 8,695 assertions, including its catalog and guide budgets.

## Lessons

Project duration is saved editing intent, not a reason to manufacture media. A compact reply must keep exceptions and final
values, even when an exception-heavy batch is longer. The lasting contracts are in
[project files](../architecture/video-edit-project-file.md#explicit-project-ending-v37-2026-11-17) and
[MCP editing parameters](../architecture/mcp-edit-parameters.md#compact-batch-feedback-and-project-endings-2026-11-17).

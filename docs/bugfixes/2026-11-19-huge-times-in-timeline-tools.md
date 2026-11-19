# 2026-11-19 A huge time in a timeline tool was stored with an undo step, and the next export or look quit SkyCut

## Symptom

An AI that passed a finite but absurd time (10^20 s: a typo, a unit mix-up) to a timeline tool got a success, and the project
kept it. `set_text start`, `set_shape start` / `duration`, `set_filter start` / `duration`, `set_canvas duration`,
`add_clips start` / `hit_at`, `edit_clip start` (the clip went to 10^20 s, and with linkage on the subtitle and text sitting on it
were deleted), `edit_clips start`, `duplicate_items start`, `edit_subtitles add` / `changes` ends, `add_voiceover lines[].start` and
`set_text motion_preset hit_at` all left a 10^20 s item or a 10^20 s timeline with an undo step. The edit itself did not crash;
the next thing that read the timeline did: an export (`ExportAudioMixdown` turned the timeline's length into a sample count,
`Double value cannot be converted to Int`) and a `look` at the timeline's end both quit SkyCut. The preview built a composition
of infinite length. Other tools took such values in silently: `edit_clip fade_in` / `entrance_duration` stored 10^20 s and
reported the clamped value, `freeze_frame duration` and `set_transition duration` clamped. Negative times were clamped to 0 by
some tools, refused by others and accepted by a few (`edit_subtitles changes[].start`). NaN and infinity, written as text ("nan",
"inf"), were refused as "must be a number", but `split_clip`, `duplicate_items`, `set_transition`, `set_filter` and
`edit_subtitles` refused them (and every other bad value) inside their undo group, so a refused call still left an empty undo
step: the user's next ⌘Z did nothing. Found while fixing web motion's duration (#489, CXR2 R6), which had the same crash in
`set_motion`.

## Root cause

- Times had no bound above. The argument reader (`AIToolArguments.double`) only checks that a number is finite, by design: each
  tool owns its ranges. Most tools checked "not negative" (or clamped to 0) and nothing else for a timeline position or a
  duration, so any finite number reached the model. Nothing in SkyCut can mean a time past one day, and downstream code converts
  times to `Int` (sample counts, frame numbers) where 10^20 traps.
- The production bound already existed, in one corner only: the official-film records and their `save_project` schema refuse
  timeline seconds past 86,400 ("the supported timeline"), and the inspector's motion-preset hit field stops at 86,400. The
  general tools never used it.
- The empty undo step: the router wraps those five tools whole in `AIUndoGrouping.step` (begin a group, run the tool, end the
  group). A tool that throws while parsing has registered nothing, and `UndoManager` keeps an empty group as an undo step
  (measured: `canUndo` true, the first undo does nothing). edit_clip already avoided this ("open the undo group only after
  validation", mcp-edit-parameters.md); these five did not.

## Fix

- One shared bound: `MCPTimeArguments.seconds` (0–86,400 s) in `Sources/SrtFlowMCPKit/MCPTimeArguments.swift`, the value the
  film records already used. The film records, their reader, the `save_project` production schema and the inspector's
  motion-preset hit field now use the constant instead of their own 86,400 literals.
- `MCPTimeArguments.paths(for:)` names every time-valued parameter of every tool (an exhaustive switch, so a new tool decides),
  and `firstOutOfBounds` finds the first one that is not a finite number in range (numbers written as text count, so "nan",
  "inf" and "1e300" are caught too).
- The router refuses such a call at the top of `routeValidated`, before it queues, starts a round, opens an undo group or reaches
  the tool (`AIEditLimits.timeRefusal`): the MCP edit-parameter contract's `invalid_parameter` with the parameter's path
  (`clips[0].start`), `requested`, `allowed` 0–86,400, `suggested`, `retryable=false`, `changed=false`, the guide pointer, and
  `batch` / `index` for a time inside a list entry. Each tool's own, narrower rule still applies inside the bound.
- `get_timeline` reports it as `edit_limits.time`; the guide's conventions topic says it in one sentence. No catalog text changed.

## Verification

- Reproduced on main `916b7972` in a full-App harness (one process per call, through `AIToolRouter.routeValidated`, background
  project): 10^20 s was stored with an undo step for 22 parameters of 12 tools; after such an edit `ExportAudioMixdown.render` and
  `look` at the timeline's end trapped (signal 5, `Double value cannot be converted to Int`), the preview composition was
  infinite; empty undo steps after refused `split_clip`, `edit_subtitles` and no-op `cut_speech` calls; negative and NaN / ±inf
  inputs as described above.
- `scripts/check-parameter-limits.sh`, new group `TimeBoundChecks` (with `TimeBoundCatalog`): every number in the catalog (251,
  batch tools through their single tool's parameters) is a listed time or named as not a time; all 104 listed time parameters
  get 10^20, the largest finite number, -1, 86,400.5 and "nan" / "inf" / "-infinity" / "1e300" through the real router: 832
  plain refusals, no edit, no undo step, no job, no file. 0, 86,400 and "12.5" pass the bound; a seek to 86,400 lands on the
  end, a text at 86,400 s is added with one undo step, `edit_limits.time` is reported. 4,232 assertions, 0 failures.
- Reverse verification: with the router's three lines removed, the same check failed 1,423 assertions (all 832 calls not
  refused as required; 259 left an edit or an undo step; `freeze_frame duration` wrote still files), exit 1. Restored: green.
  The catalog half, checked alone with a copy of the table missing `seek.time` and naming a non-existent `set_canvas.end`:
  both reported, exit 1.

## Lessons

- "Finite" is not "in range" (the web-motion case said so for one tool; it held for all of them). A bound that exists in one
  corner of the product belongs to everything that takes the same kind of value.
- Validate before the undo group opens. A tool wrapped whole in `AIUndoGrouping.step` turns every refusal, for any reason, into
  an empty undo step; the router's bound now runs before that for times. Refusals for other reasons inside those five tools
  (and successful no-op calls such as a `cut_speech` that cuts nothing) still leave an empty step; that is a separate item.
- A project file that already holds such a time (written before this fix) still breaks export and look: the bound covers what
  an AI passes, not what a file brings in.

The rule is in [MCP edit parameters](../architecture/mcp-edit-parameters.md) ("Times in every tool"). Related:
[web-motion duration](2026-11-19-web-motion-huge-duration-quits-app.md).

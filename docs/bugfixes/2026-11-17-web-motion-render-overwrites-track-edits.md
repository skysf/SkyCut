# 2026-11-17 A web-motion render overwrites newer track edits

## Symptom

During development, start re-rendering an existing motion clip with an explicit upper-track destination,
then move the clip vertically without changing its time. The old render can move it back. Hiding its source
lane during rendering can likewise make the result visible elsewhere. Reordering or removing an existing
destination while an AI job is queued can send the result to the lane now occupying its old index.

A separate successful lane-only `set_motion` call can report `unchanged` and omit its saved round version,
even though the clip moved to another lane.

## Root cause

`EditClip` owns source, timing and effect values; lane ownership and visibility live outside that value.
The two asynchronous boundaries checked document generation and clip equality, which do not detect a
vertical-only move or a lane visibility edit. Explicit destinations were also stored as mutable indexes
until the service started. The AI change-reporting predicate had the same blind spot: equal clip values
were treated as an unchanged timeline.

## Fix

`WebMotionSourceLane` captures the source lane identity and visibility. `AIMotionRequest` captures it before
queuing; `AIMotionTool` checks it before rendering; `WebMotionActions` checks it again after rendering and
probing, alongside the existing document and clip checks. A mismatch preserves the newer timeline and
creates no undo step. A reorder of the same lane remains valid because the comparison uses its UUID.

An existing requested destination is captured by UUID and resolved before the service starts. The service
then retains that identity across its own await. A removed or hidden destination uses the existing new
upper-track fallback. New/insert targets retain their existing positional policy.

The successful AI call compares both the clip and source-lane context when deciding whether to note/save
the round. An intentional lane-only move is a change and reports its before-round version.

## Verification

The isolated App/helper fixture drives real rendering, `relocateClip`, queued AI calls, undo and saved
versions with synthetic pages. It proves that clip equality can remain true while lane ownership changes.

- The initial source-context regressions failed 7/124 assertions before the fix.
- Independently removing the after-render source gate failed 5/124; removing the pre-start source gate
  failed 2/136. Restoring each gate restored the intended behavior.
- With source gates present, the old destination-index behavior failed 2/136 (reorder and removal).
  Independently restoring that old resolver also failed 2/136.
- The old lane-only reporting predicate failed 3/143 (unchanged reporting, before-round version and
  round-end version). Independently removing just the lane comparison also failed 3/143.
  After exact restoration, the complete fixture passed 143/143.

The exact restored production source passed `scripts/check-motion-placement.sh`.
`scripts/check-local.sh mcp` runs every scan guard and the complete MCP checks.

## Lessons

An async edit must capture the ownership and visibility stored outside the edited value. Keep stable lane
identities across every queued/await boundary, and include intentional lane changes in change reporting.
The permanent contract is in [Web-motion renderer](../architecture/web-motion-renderer.md).

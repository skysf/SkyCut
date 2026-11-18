# 2026-11-18 A later automatic gain join breaks an earlier seam

## Symptom

Three adjacent shots have constant material levels -10, -20 and -30 dB. set_transition all=true sound=gain returns two
completed cuts, but final levels are -20, -30 and -30: the first seam is mismatched again by 10 dB.

## Root cause

CutSoundPlanner processed cuts sequentially in one mutable state. Automatic gain shifts a sound's whole volume line;
matching B to C therefore changed the incoming sound previously matched at A/B. Each outcome recorded its intermediate
gain rather than the total adjustment in the final state. Existing multi-cut checks covered crossfades, not automatic gain.

## Fix

CutSoundBatchGain validates and measures each seam against the original state, builds the shared-sound constraints and
solves each connected component together. It chooses the least attenuation that satisfies every seam without raising a
sound. Each sound is shifted once. Every outcome reports the final total adjustment at that seam, including volume clamps;
an unavoidable residual is explicitly reported as not fully matched. Conflicting shared-sound constraints are refused
atomically. Silent cuts still skip, disconnected components remain independent and explicit gain_db keeps its behavior.

## Verification

- Reproduced the production planner on main 8a16cccb with synthetic shots and supplied constant material levels: final
  [-20, -30, -30], two outcomes, first seam mismatched by 10 dB. This is planning after measurement, not real-file metering.
- CutSoundBatchGainChecks validates every seam after the complete batch: descending / ascending / valley / equal chains,
  reversed cut order, separated sound, curves and faders, silent gaps, volume-floor reporting, invalid later input,
  conflicting shared sound and explicit gain controls. Outcome gains are checked against the final clip values.
- Reverse verification removes the automatic batch dispatch, restoring the old sequential planner. Final seam and report
  assertions turn red (19 batch failures, plus four resource failures in the same MCP run). Restore the dispatch and run scripts/check-local.sh parameter-limits mcp.

## Lessons

Whole-object edits shared by several constraints must be planned together. A successful intermediate edit does not prove
the final batch satisfies it. The lasting rule is in [sound across a cut](../architecture/cut-sound.md), rule 11.

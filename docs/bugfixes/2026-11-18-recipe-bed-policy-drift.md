# 2026-11-18 Shared editing rules teach the bed decision backwards

## Symptom

recipes id=shared-rules tells every style to dip both sides of a cut toward the bed and edit volume_curve manually.
The production bed tool instead raises the bed first and lowers only what its volume limit cannot cover.

## Root cause

The shared resource still contained the previous bed policy after the production planner and architecture changed in
PR #439. Existing resource checks validated sections and tool names, but did not compare this audible decision.

## Fix

The shared Cuts rule teaches raising the bed first to within 6 dB of the louder side, with side attenuation only for the
residual beyond the bed's volume limit. It directs the AI to set_transition sound=bed. The corresponding plan is synchronized;
other sound crossings and manual curve editing outside this policy retain their contracts.

## Verification

- The actual production recipes reply on main 8a16cccb contains both sides dipped toward it. No AI edit or media generation
  is needed to reproduce a contradictory instruction that is actually delivered to clients.
- RecipeSoundChecks loads the shipped resource through AIRecipeTools.recipes, isolates its Cuts section and verifies the
  raised-first policy, 6 dB margin, volume-limit exception and production-tool route. Existing CutSoundDecisionChecks /
  CutSoundLevelChecks verify the matching planner behavior on uncapped and capped beds.
- Reverse verification restores the old resource; all four resource-policy assertions fail. Restore it and run
  scripts/check-local.sh parameter-limits mcp. The check uses a temporary empty user recipe store.

## Lessons

Behavior, architecture and the instructions delivered to AI clients are one contract. A valid tool name does not prove the
policy taught around it is current. The lasting rule is in [sound across a cut](../architecture/cut-sound.md), rule 9.

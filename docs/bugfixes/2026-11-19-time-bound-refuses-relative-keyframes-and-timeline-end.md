# 2026-11-19 The one-day time bound refused relative keyframes a hair below 0 and times the tools had just made

## Symptom

Two kinds of ordinary AI calls started failing after the time bound (#503,
[case](2026-11-19-huge-times-in-timeline-tools.md)), found by review CXR3 (R12):

- `set_keyframes` with `relative: true` and a fraction a hair outside 0–1 — `-0.0005`, the rounding of a computed fraction —
  was refused as "scale[0].time must be 0.0 to 86400.0", although the tool has always taken −0.001–1.001 and clamped it to the
  clip's edge. A fraction just above that (`1.002`) still reached the tool and got its plain-text refusal instead of the
  contract's `invalid_parameter`.
- The tools could make a timeline that runs past the day and then refused to use it: `set_text start=86400 duration=2` is
  accepted (each time is inside the bound) and ends the timeline at 86,402 s, but `seek` to that end, `look` at 86,401 s and
  moving the text to 86,400.5 s were all refused as past 86,400.

## Root cause

The bound treated every listed time as seconds on a one-day timeline. A relative keyframe time is a fraction of a clip, not a
second, and the bound for it is the tool's own −0.001–1.001; the router knew nothing about `relative`. And the bound for a time
on a project ignored the project: a check at the top of `routeValidated` runs before the call's project is known, so it could
only apply the day, even to times inside a timeline the same tools had just made longer.

## Fix

- `MCPTimeArguments.allowed(tool:arguments:timelineEnd:)` decides the range: the day, or up to the project's end when that
  already runs past it; `relativeFractions` (−0.001–1.001) for set_keyframes' times when `relative` is true. `relative` is read
  the way the tools read any yes / no (`JSONValue.flagValue`, now also behind `AIToolArguments.bool`), so `"true"` counts.
  AIKeyframes uses the same `relativeFractions` (one rule).
- `Finding` carries the range it was outside; the refusal's `allowed` reports it.
- The router checks in `execute`, as soon as the call's project is known (`target?.state.duration`) and still before a round,
  an undo group or a job — no longer before the call queues: a refused call has only waited in its line.
- The guide's conventions topic says both edges in one sentence each.

## Verification

- `scripts/check-parameter-limits.sh` → `TimeBoundEdgeChecks` (real router, TimeBoundChecks' background project): a 2 s text
  at 86,400 s ends the timeline at 86,402 s; a seek to that end lands there, a look at 86,401 s answers, the text moves to
  86,400.5 s; a seek past the end is refused with that end as `allowed.maximum`. Relative fractions −0.0005 and 1.0005 land on
  the clip's source edges (with `relative: true` and `"true"`); −0.002, 1.002 and 10^20 are `invalid_parameter` with −0.001–1.001
  and change nothing. 4,243 assertions, 0 failures; the 832 refusals of `TimeBoundChecks` are unchanged.
- Reverse: the same check on main's code (production files stashed): 9 failures, exit 1 — the four timeline-end checks refused
  as past 86,400, the two relative calls refused as negative, the three out-of-range fractions with the seconds range or the
  tool's plain text. Restored: green.

## Lessons

- A shared bound needs the units of what it bounds: a fraction is not a second. When a parameter changes meaning with a flag,
  the bound must read the flag the same way the tool does.
- A bound that the API itself can step over (start and duration each in range, their sum not) must either refuse the sum or
  accept what it allows to exist; refusing to read back what was just written breaks the AI's next call.

Rule: [MCP edit parameters](../architecture/mcp-edit-parameters.md) "Times in every tool". Not fixed here (recorded in the bug
backlog): long-source positions past a day in `look file=` / source windows, and set_motion's `parameters.duration` /
`parameters.hit` aliases.

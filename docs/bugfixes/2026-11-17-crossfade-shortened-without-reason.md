# 2026-11-17 A valid crossfade was shortened without an explanation

## Symptom

MCP-6 requested a 1.042 s crossFade between two touching clips longer than 1.5 s, with unused footage on both sides.
`set_transition` returned 0.6 s and `shortened_from: 1.042`, without saying which limit caused the change.

## Root cause

Touching cuts always used a conservative 40% ceiling based on the shorter clip. That ceiling protected an implementation
detail: preview and export would apply packing's 45% rule again after the clips were expanded with borrowed handles.
Raising the first ceiling alone would still shorten the rendered overlap and could stretch the exported timeline.
`AITransitionReport` reported the shortening but omitted the native maximum and reason.

## Fix

`TransitionDurationLimit`, in `VideoEditTransitionHandles.swift`, keeps the conservative allowance and additionally allows
a longer centred window when both sides have real footage for half the request. Each half uses at most 45% of its adjacent
clip and newly applied transitions remain capped at 2 s. One-sided footage, freeze fallback and magnet packing retain their
existing limits. Saved overlaps keep their legacy rendering, including a previously stored 3 s transition. The render copy
settles any originally overlapping seam before expansion, then preview/audio and export read the
same actual geometric overlap. No persisted flag or format field is added.

`AITransitionReport` adds `max_duration` and `shortened_reason` whenever it reports `shortened_from`. The guide explains the
native limits and tells the AI to relay a shortening notice. The edit still follows the existing single commit and undo path.

## Verification

- `scripts/check-mcp.sh`: the 1.042 s request is preserved with handles, no frames freeze, total length stays 3 s, magnet's
  static overlap remains 0.675 s, and shortened requests report their maximum and reason.
- `scripts/check-video-fade.sh`: synthetic white/black clips go through the production preview and export pipelines;
  quarter-window brightness proves the full dissolve renders, and the output remains 3 s. Passed: 246 checks, zero failures,
  including the existing zero-handle, one-sided-handle and still cases.
- `checks/transition-handles-wiring.sh`: both render overlap consumers use the shared geometric rule and export does not
  reintroduce the packing percentage. Restoring export's old 45% calculation made this guard exit 1; restoring the shared
  rule made it pass again.
- Reverse verification: temporarily disable the centred allowance and omit the new report fields, then run the MCP check.
  It exits 1: the new duration assertion receives 0.6 s instead of 1.042 s and the maximum/reason assertions fail. Restore
  both production files byte for byte. A saved 3 s overlapping seam also has explicit coverage, preserving its overlap and
  17 s timeline instead of rewriting it to today's UI ceiling.

## Lessons

Do not apply an editing/packing limit again to a render copy whose overlap has already been settled. A limit notice must
name the maximum and why it applies, using the same calculation that constrained the edit. The current rules and manual
regression checklist are in [the transition contract](../architecture/transition-handles.md).

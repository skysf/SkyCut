# 2026-11-18 Official motion clip names stay in the creation language

## Symptom

Add an official motion in English, select its clip, then switch SkyCut to Chinese or Spanish. The library card and motion-parameter
heading use the new language, but the timeline clip label and the inspector's top header still show the stored English template name.

## Root cause

The official-label resolver recognized default names in every supported language, but only the new cards and parameter form used it.
Both existing clip consumers still drew `Text(clip.name)`. That property intentionally returns the saved source name; changing the app
language does not and must not rewrite project data. Pure label-resolver tests passed while these production views bypassed them.
Calling the resolver once in a view is also insufficient: the resolver reads the language snapshot, so a persistent label needs an
explicit SwiftUI locale dependency to redraw after the user changes languages.

## Fix

`WebMotionClipName` displays the recognized official default through `OfficialWebMotionLabels.title` and observes the environment
locale. Both the timeline name row and inspector header use it for web clips; ordinary media retain their existing name branch.
Custom web names remain verbatim, and no saved name, HTML, parameter value, clip identity or media path is modified.

## Verification

The App-linked `checks/MotionPlacement/ClipNames.swift` fixture constructs an English official record and its hosting view once,
switches the app language to Chinese, Spanish and back to English, and compares the real rendered label with a localized reference.
It also retains a mounted custom-name view across the same switches and requires its pixels to stay unchanged. A production wiring
guard requires the shared view in both actual consumers. The official offscreen harness includes the full 252-point inspector and
real timeline clip block in all three languages and both themes, using the same stored English records.

- Final restored `scripts/check-local.sh motion-placement localization-coverage`: all scanning guards, 362 real App integration
  assertions and all 1,313 localization entries passed. The first sandboxed attempt could not build the SwiftPM manifest
  (`sandbox_apply: Operation not permitted`); the same finite command passed with a scoped escalation and unchanged checks.
- Replacing each consumer independently with its old `Text(clip.name)` branch made `checks/MCP/motion-wiring.sh` exit 1;
  restoring each branch returned its attachment guard to green.
- Removing only the view's locale environment declaration/read made the real App fixture fail exactly 4/362 assertions:
  the Chinese and Spanish mounted labels retained English, differing from their localized references. Exact restoration
  returned all 362 assertions to green. Custom-name preservation continued to pass in the reverse.
- Evidence logs: `/tmp/g26-c-clip-name-reverse-{1,2}.log`, `/tmp/g26-c-clip-name-reverse-locale.log` and
  `/tmp/g26-c-clip-name-final-check-local.log`.
- The final `render-motion-presets.sh <output> --official-only` run produced 69 PNGs: 66 actual UI screenshots and three decoded
  movie-frame contact sheets. All 66 UI captures used `screencapture`; none needed the enabled explicit drawing fallback.
  Reviewing the 36 added inspector/timeline captures confirmed localized default names and fit in every language/theme.
  Capture log: `/tmp/g26-c-clip-name-captures.log`.

## Lessons

Resolver tests cannot prove that existing UI consumers call that resolver, or that a retained view reacts to a locale change.
Cover all visible consumers and an actual language switch without reconstructing the view. Keep display localization separate from
authored data and persisted names; the durable contract is in [Motion presets](../architecture/motion-presets.md#9-original-official-web-templates-2026-11-18).

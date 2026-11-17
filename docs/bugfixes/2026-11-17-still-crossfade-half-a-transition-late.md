# 2026-11-17 A crossfade between two stills played half a transition late

## Symptom

- Walking the film-craft knowledge cards in SkyCut 0.18.66 (card 315, stills): two PNG stills on V1, then
  `set_transition after_clip_id=<first> type=crossFade` → `{"cut":13.967,"from":13.717,"to":14.217,"duration":0.5}`. In `look`
  and in the export the first still was unchanged until about 14.0 s, about half blended at 14.217 s and gone near 14.47 s:
  the dissolve ran from the cut for a whole transition, half a transition later than the result and the timeline mask said.
  It was the same with the stills' scale keyframes removed (a control run). Crossfades between untrimmed video clips were
  centred.
- Reproduced on main (5abca0d4) with the new check: two 4-second stills, a 1-second crossFade on the cut at 4 s. In the preview
  and in the export the first still was at 100 % at 3.75 s and 75 % at 4.25 s (centred: 75 % and 25 %); white → black and
  black → white alike.

## Root cause

- A transition between touching clips is made by extending both into footage they do not use (handles) so they overlap by d;
  both pipelines and the audio engine render that one plan (`TimelineState.transitionExtension`,
  [transition handles](../architecture/transition-handles.md)). The plan ate the **outgoing tail first** (`borrowSplit`): up to
  d from the outgoing clip, only the rest from the incoming head. Frames were held only when both sides together had less than d.
- **A still is a 60-second clip used from its first frame**: 56 s of "tail", nothing before it. So the whole transition always
  came from the outgoing still's tail and played over [cut, cut + d], while the mask (`transitionWindow`) and set_transition's
  result say [cut − d/2, cut + d/2]. Holding a still's frame would have cost nothing — it is the same picture — but the planner
  treated the hold as a last resort for frozen video.
- The same tail-first rule put the transition after the cut for every outgoing **video trimmed at its end** (tail ≥ d), even
  when the incoming clip had head footage too. This was written down in 2026-09-20 as a "known misalignment" and left alone
  because the only alternative weighed was symmetric borrowing with frozen frames; centring with footage from both sides needs
  no frozen frame at all.
- Not involved: #441 (the transparent still's one shared frame) — opaque H.264 stills (the walkthrough's PNGs had no alpha) and
  shared-frame ProRes stills behave alike; and the keyframes were never dropped (the new check passes the keyed scenario before
  the fix too; the walkthrough's "also with the scale keys removed" was its control run).

## Fix

- `TimelineState.transitionExtension` (`Sources/SrtFlow/VideoEditTransitionHandles.swift`) centres the window whenever no moving
  picture has to freeze: each side reaches d/2; a still (`EditClip.showsOnePicture`) reaches by holding its first or last frame
  (`renderHoldHead` / `renderHoldTail`, which the preview — `CompositionHold` — and the export — `tpad` — already render); a
  side short of footage hands the rest to the other side's footage (`centredSplit`). Moving pictures are held only when the
  footage of both sides together is shorter than d (unchanged, 2026-09-23 decision).
- Preview, export, prerender and the audio engine all expand with that one function, so they changed together; the stills'
  keyframes are evaluated on the expanded copies as before (a held head clamps to the first key).
- set_transition's result (`AITransitionReport`) now says where the transition really plays — `renderedTransitionWindow`, the
  drawn window except where one side lacks footage for its half — and never calls a still's hold a frozen frame.
- Visible change for video: seams where both clips have footage for their half are centred now (were after the cut). One check
  moved with it: `checks/MCP/CutSoundChecks.swift` (B's sound runs into the B|C dissolve to 8.25 s, was 8.5 s).

## Verification

- `scripts/check-video-fade.sh` → `checks/VideoFade/StillCrossfade.swift` (new; stills made with the production conversion
  arguments in the check's own folder): the plan (each side d/2, the incoming still holds its first frame, render copies
  overlap 3.5–4.5 s, rendered window = drawn window); preview and export at 3.75 s and 4.25 s for white → black and black → white
  H.264 stills (both cover the frame, so the preview is the exact dissolve: 0.75 / 0.25 and 0.25 / 0.75); keyframed stills (an
  H.264 one shrinking, a shared-frame ProRes one growing): the edge is black and the middle shows both in both pipelines.
- Reverse: the planner back to tail first → 12 red (plan 4, preview 4, export 4: e.g. preview 1.0 / 0.749 instead of
  0.75 / 0.25) → restored: 239 of 239.
- `scripts/check-mcp.sh` → `TransitionReportChecks.swift`, two new cases: two stills (from 3.75 to 4.25, no `holds_*`), footage
  on one side only (from 5 to 6). Reverse: the report back to the drawn window and no still filter → 3 red → restored: all
  8099 MCP checks pass, the moved cut-sound expectation included.
- The other users of the expansion (audio fades, audio engine, film production, preview composition, freeze frame, timeline
  snap) are symmetric, zero-footage or overlapping seams that do not change; CI runs them all.

## Lessons

- "Prefer real footage over a frozen frame" has to ask what a frozen frame is for this clip: for a still every frame is the
  same, so the hold is free and the transition can sit where it is drawn.
- A "known misalignment" left in a doc is a bug the AI will hit: it reads the result and looks at those frames. The fix that
  was dismissed (symmetric with freezes) was not the only one; centring with both sides' footage freezes nothing.
- A result that tells the AI where something happens must come from the function that renders it, not from the one that
  draws the UI. Long-term rule: [transition handles](../architecture/transition-handles.md) ("首尾相接", "已知未对齐").

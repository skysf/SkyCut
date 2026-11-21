# 2026-11-21 A voice change finished as a success with no speech in it

## Symptom

In the user's B07 course project, the separate audio clip of `B07 Omni Intro Full` (15 s, three complete English lines of AI
speech) was changed to the library voice Sky English V2. The job ended done and landed as usual: two new audio tracks, the
original muted. But the new voice track had no recognisable speech; the three lines were in the background track. A 5 s trial
of the same flow had worked, so nothing warned the user before paying.

## Root cause

1. **Sky Studio's default flow trusted the separation.** `voice_convert` runs SAM (speech / background separation) and then
   Chatterbox HD on the separated voice. On this clip SAM left the dialogue in the background stem; Chatterbox converted an almost
   silent voice stem, and nothing compared the stems before paying for the conversion, so the job reported success with both
   files (fixed in Sky Studio, lane VC1: a speech check after SAM that ends the job `separation_failed`).
2. **SkyCut had only that one path.** The panel and `change_voice` could not send a clip that is already a clean voice (AI or TTS
   speech, an isolated dialogue track) straight to the conversion, which is cheaper and has no separation to fail.
3. **SkyCut's books knew only "all" or "nothing" for a failed job.** `VoiceChangeJob` refunded the reservation when the failure
   proved a full refund (`canRefund` → `billing.returnedAll`) and otherwise kept the whole quote. Sky Studio already kept the
   separation's part and returned the rest when both conversion models failed after the separation; such a job stayed on this
   Mac's daily books at the whole quote. `separation_failed` makes that the common case, so it had to be fixed with it.

## Fix

- **Direct change** (`skip_separation`): the panel's checkbox 「直接换声（跳过人声分离）」 and `change_voice`'s optional boolean put
  `params.skip_separation` into the one draft (`VoiceChangeOrder.draft` → `SkyStudioVoiceRequests.convert`, always a JSON
  boolean). The job is that draft plus the upload, so the quote and the job carry the same value. A direct quote must confirm it
  (`voice_plan.skip_separation`, `SkyStudioVoiceRequests.quoteConfirms`) or nothing starts.
- **One-track results**: `SkyStudioVoiceConversion.backgroundURL` is optional; `VoiceChangeJob` downloads only the voice for a
  direct change and `VoiceChangeLanding` lands it on one new track, the original muted and linked, in the same single `perform`
  inside `AIUndoGrouping.step`. A default change without its background lands nothing.
- **`separation_failed`** (`SkyStudioVoiceCodes.separationFailed`): the job fails (never done), nothing lands, the source keeps
  playing; the cloud task row and the panel's notice bar show 「人声分离失败，可改用直接换声」 by the code; get_job carries the code
  and a `next_step` to retry with `skip_separation=true` only for a clean voice; the panel opened again on that clip starts with
  the checkbox on (`VoiceChangeActivity`).
- **Books**: a failed job settles at Sky Studio's final net charge when it reports one above zero (`VoiceChangeJob.settle(failed:)`).
- The guide topic's `direct_change` section, the card's one-track clause and the parameter description tell the AI when to use it.

## Verification

- `scripts/check-voice-recovery.sh` (`VoiceChangeDirectChecks`, real App objects against the fake Sky Studio `VoiceChangeHTTP`):
  the direct order's quote and job both carry `skip_separation: true`, the voice lands on one track and one undo restores the
  source; the default order still carries `false` and lands both tracks; `separation_failed` fails with nothing landed, the
  source unmuted, 6.5 of the 9 reserved on the books, the localized line in the task row and the notice bar, and the panel opened
  again with the checkbox on.
- `scripts/check-sky-studio.sh` (`VoiceJobChecks`): the request bodies, a voice-only result, `separation_failed` parsing.
- `scripts/check-mcp.sh` (`SkyStudioVoiceChecks`): the parameter, the card, the `direct_change` section.
- Reverse checks (each fix undone, the check run red, the fix restored): the table in
  [voice library](../architecture/voice-library.md) section 11, 2026-11-21.
- Not verified here: the real Sky Studio (the server side ships separately and has to be live first), the real B07 clip (user
  data, read-only), the panel in a real window (manual regression list in the same section).

## Lessons

- A paid job with several stages can fail after a stage that was charged: settle on the server's final net charge, never "all
  or nothing".
- When an automatic pre-processing step can quietly ruin some inputs, give the user and the AI a direct path that skips it and
  say when to choose it.
- Long-term rules: [voice library](../architecture/voice-library.md) section 11, item 12.

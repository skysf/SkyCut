# 2026-11-26 After a failed download, the upscale and change-voice panels offered only the paid button again

## Symptom

A paid upscale or voice change whose result did not come down (the network cut the download, or it could not be saved) keeps
the result on Sky Studio for Download again on its task row (#554). Opening the upscale or change-voice panel on the same clip to
try again showed only the usual paid button ("Upscale · N credits", "Change Voice (up to N credits)"): pressing it started a new
paid job and charged again, while the free Download again sat in the task list (backlog B47). The AI side had the same shape: an
identical request sent again (generate_media without the job's key, upscale_clip, change_voice) is a new paid job, and nothing
told the AI it was repeating itself or stopped a runaway loop of them (B51).

## Root cause

- PR #554's second round matched a new request to an old held job by its parameters (the source file, the arguments), so the
  panels and tools could offer Download again. It returned wrong results (a 9:16 request got the old 16:9 image, project B's
  upscale got project A's clip) and was reverted; the narrowed round kept Download again only on the job's own row, id and key,
  and the panels were left with nothing to say about a held result.
- The panels could not know their clip's own last job: an upscale job knows the clips it covers and its project's opening, but a
  voice change job was recorded nowhere by its clip.
- An identical paid request sent again is a deliberate new version (user, 2026-11-25), so SkyCut must not refuse or redirect it;
  with nothing counting them, nothing could tell the AI or ask before a loop.

## Fix

- Panels: `SkyStudioPanelHeldDownload` finds the clip's own held job by the job's own identity (an upscale job covering the clip in
  that opening of the project; the voice change last started for the clip, noted in `VoiceChangeActivity` by `VoiceChangeOrder.start`),
  never by parameters. When there is one, the panel makes Download again its default button and labels the paid one "Make a new
  version (N credits)", under one line saying which is which, in English, 简体中文 and Español.
- AI tools: `SkyStudioRepeatGuard` counts identical resolved requests (`SkyStudioRequestDigest`) per project and tool. From the
  2nd the result says which one in a row and its credits; the 5th asks once through `SkyStudioJobGate` in every permission mode (one
  question with the draft question when there is one); a yes covers the rest of that run. change_voice takes `confirm_token` for
  it. Panels are never counted.
- The rules: [Sky Studio jobs](../architecture/sky-studio-jobs.md), "Identical paid requests in a row".

## Verification

- `scripts/check-voice-recovery.sh` → `RepeatPanelChecks`: after three dropped GETs the change-voice panel on that clip holds
  Download again and another project's does not, and its Download again lands the change with no new POST; an upscale held after
  three drops is offered on its clip in project A, not on the same source's clip in project B or on a clip it did not cover, and its
  Download again sends no new upload or POST; identical changes and upscales from the panels are never counted.
- `RepeatRequestChecks` (the tool entries, POSTs counted) and `RepeatGuardChecks` (`scripts/check-sky-studio.sh`) cover the AI side;
  `checks/sky-studio-wiring/repeat-requests.sh` pins the wiring. Each was reverse-verified (see the PR description).
- Off-screen images of both panels with a held result, in en and zh-Hans, were rendered for the user before merge.

## Lessons

- Offer a held paid result only by the job's own identity (its clip, its project's opening): matching a request's parameters hands
  people someone else's result.
- When the same paid action may be started again on purpose, do not block it: make the free path the default, name the paid one for
  what it is, and ask once before a loop.

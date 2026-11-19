# 2026-11-20 CI: the full-App checks over three shards, and cheap flakes

The user, 2026-11-19: make CI itself faster without lowering its quality. Every check that ran before a merge still
runs before that merge; nothing moved to a nightly run and nothing is skipped by path. The rules are in
[Build and packaging "CI"](../build/build-and-packaging.md).

## 1. What changed

| PR | Change |
| --- | --- |
| #523 | The full-App checks spread over shards 1–3; one full-App `.build` cache for every shard, saved on main by shard 1 right after its App build; shard 1 is the light graphical shard |
| this report's PR | Diagnostic uploads can't fail a shard ([case](../bugfixes/2026-11-20-ci-artifact-upload-fails-green-shard.md)); `scripts/ci-step-failure-rates.py` as a daily signal |

## 2. Why

On 11-19 a run took as long as its shard 1, 27–31 minutes: shard 1 held every check that links the full App, and those
grew in two days (video-inspection under 40 s → about 6 minutes; motion-placement new, about 5.5 minutes; e2e,
e2e-gui and the playback benchmark new). Shards 2–5 took 8–11 minutes. A flaky benchmark re-ran all of shard 1.

## 3. Times

Job minutes per shard (runner time, not counting the wait for a runner):

| | shard 1 | 2 | 3 | 4 | 5 | longest | runner-min |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Before: median of 25 green PR runs, 11-19 | 26.9 | 11.0 | 9.2 | 8.3 | 8.6 | 26.9 | 62.5 |
| #523's run (cache: the old shard-1 one, 7c5fd36c) | 13.7 | 13.9 | 14.1 | 14.5 | 14.2 | 14.5 | 70.4 |
| #525's run (the shared `-app-` cache main saved after #523) | 12.4 | 9.8 | 15.7 | 12.3 | 12.1 | 15.7 | 62.3 |

- Shard 1 in #523's run: restore 8 s, Build app 67 s, playback benchmark 135 s, its checks 409 s, preview perf ratchet
  172 s. A timing flake re-runs this job: about 14 minutes instead of about 28.
- Shards 2 and 3 compile the App inside their first full-App check (project-versions 53 s, motion-placement 394 s
  including it).
- With a stale cache, runner minutes per run go up by about two App builds (#523's run). With the fresh shared cache
  they don't (#525's run: 62.3, against 62.5 before). Shard 1's Build app took 16 s there, against a median of
  1.6 minutes on 11-19, when a busy main rarely lasted long enough to save. Main's run after #523 saved the cache
  about two minutes after it started, and was later cancelled by the next merge.
- The two runs' longest shards were 14.5 and 15.7 minutes, on different shards: hosted runners differ by 1.5–2×, so a
  shard's time moves by minutes from run to run. #525's run executed the same 118 checks (none missing, none extra,
  none twice).

## 4. Coverage is the same

- `scripts/check-all.sh`: the sorted `run_check` lines before and after are byte-identical (118 lines, names and
  commands); only `shard` blocks changed. The workflow runs each graphical step once, with the same conditions.
- #523's run (44568227033) executed exactly the 118 declared checks: the union of its five shard logs has none
  missing, none extra, none twice. The 11-19 run used for comparison (44546773274) executed the 117 declared at its
  base; the 118th, test-app-cleanup, was added to main after it.
- Guards that keep it so (each reverse-verified on 2026-11-20 by mutations that turn it red):
  - `checks/check-all-shards.sh`: every command exactly once; no check script drops out of CI; full-App checks only in
    shards 1–3; the graphical steps after the dedicated App build in its shard; uploads can't fail a run.
  - `checks/ci-build-cache-key.sh`: one shard-independent key, the restore order, the single early save after the
    complete App build.

## 5. Flakes

- The artifact service timed out on an upload on 11-17 and turned a shard red whose checks had all passed; uploads are
  now `continue-on-error` ([case](../bugfixes/2026-11-20-ci-artifact-upload-fails-green-shard.md)).
- `scripts/ci-step-failure-rates.py` on 11-19 to 15:10 UTC, without the two calibration branches: the playback start
  benchmark failed in 20 of 30 pull-request executions on CI1's snapshot (19 of 28 counting only executions that
  finished by 15:10). It was recalibrated in #513 at 14:47 UTC; run the script daily to see whether that held.

## 6. Not done here

- Testing every merge on the exact tree that lands (a merge slot): the user chose it on 2026-11-20; a separate PR.
- A self-hosted Mac: not now (the user, 2026-11-20).
- Reusing a check's result when its inputs didn't change: needs the user's decision.

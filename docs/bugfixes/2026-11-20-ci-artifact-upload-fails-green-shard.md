# 2026-11-20 An artifact upload timeout turned a green shard red

## Symptom

- On 2026-11-17, attempt 1 of PR run 43997530244 (`fix/fills-frame-rotation-and-edges`): every check in shard 1
  had passed, and shard 1 still went red. The summary job `check-all` failed with it, so the PR couldn't merge.
- The red step was "Upload preview performance results". The artifact service timed out five times:
  `##[error]Failed to CreateArtifact: Failed to make request after 5 attempts: Request timeout: /twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact`.
- Re-running the failed jobs (attempt 2) was green, but shard 1 was the longest job then, so getting a result that
  was already known cost a whole shard again.

## Root cause

- The shard job uploads two diagnostics: "Upload playback start samples" and "Upload preview performance results".
  They carry the samples and logs that help read a failure; they decide nothing.
- The gates are the measuring steps themselves, the playback start benchmark and the preview perf ratchet. Both had
  passed.
- But the uploads were ordinary steps, so a failed upload failed the job. The summary job's marker uploads already
  had `continue-on-error: true` for the same reason (a missing marker must not turn `check-all` red); the shard
  job's two uploads never got it.
- 11-13 to 11-19: 1 of 29 failed shard jobs ([CI throughput analysis](../reports/2026-11-20-ci-rebalance.md)).

## Fix

- `.github/workflows/checks.yml`: `continue-on-error: true` on both uploads. A failed upload still shows as that step's
  failure and an annotation; the shard keeps the result of its checks.
- `checks/check-all-shards.sh`, rule 6: every `actions/upload-artifact` step in the workflow, in any job, carries
  `continue-on-error: true`.
- The rule is in [Build and packaging "CI"](../build/build-and-packaging.md).

## Verification

- `checks/check-all-shards.sh` is green with the fix.
- Reverse verification: each of the following turns it red, naming the step:
  - `continue-on-error` dropped from "Upload playback start samples";
  - dropped from "Upload preview performance results";
  - dropped from the summary job's marker upload;
  - set to `false`;
  - a new upload step without it.
- Real failures still fail: `continue-on-error` sits only on the upload steps. The benchmark, the ratchet and
  `check-all.sh` keep failing the shard as before.

## Lessons

- A step that only reports, but can fail the job, is a gate in disguise. Give every diagnostic step
  `continue-on-error`, and pin it with a guard so the next upload gets it too.
- Infrastructure that times out (here the artifact service) shouldn't decide whether a change is good. Where a step's
  result does matter, it has to fail the run, and the author re-runs it as a known flake (AGENTS.md 「合并与分支」).

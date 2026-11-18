# 2026-11-18 An implicit look waits for a project switch outside its answer timer

## Symptom

A session has a slow new_project, or close_project waiting behind an edit, and concurrently sends a timeline look without
an explicit project argument. The look can wait beyond its 25-second answer budget without a job id, queue position or
cancel_job entry. A remembered project stamp does not make the project argument explicit.

## Root cause

AIToolRouter awaited queueKeys before entering AILookCall. queueKeys first waits for the session's switch tail so it can
choose the correct current project. AILookCall's timer therefore covered only the project queue and rendering. Existing
LookProject checks joined a known project's line directly and never exercised this selection wait.

## Fix

The look's timed lifecycle begins before asynchronous line preparation. AILookCall tracks the captured switch predecessor
while queueKeys waits, reports that wait as a queued job, and binds its project / Stop owner only after selection returns.
The target still comes from the session after the switch, never from a stale remembered stamp. Pending jobs can be cancelled
immediately without releasing another call's place; their gate prevents later execution. Explicit-project and file looks
keep their existing queues. The router exposes its already-authorized routing boundary to isolated checks; protocol,
argument and license guards still run before that boundary in production.

## Verification

- Reproduced main cb661ae6 through the actual authorized router entry, extracting only that test boundary and adding a
  phase observer while retaining the old queue-before-timer order. The projects are real, isolated background projects. Without the fix, both implicit variants (with / without a remembered stamp) enter queueKeys' exact
  switch-wait phase and fail to return a job while the predecessor is held. A shortened answer timer and a broad watchdog
  make the regression bounded; the held calls are released in cleanup. Five new assertions fail; existing look checks pass.
- RouterSwitchChecks covers queued job status, position and waiting_for; no old project binding while waiting; a project
  chosen after the switch, then its actual edit queue and Stop ownership; the final stamped look and picture through get_job;
  cancel_job and Stop during selection; explicit-project and file controls; a real close_project behind a held edit, which
  completes despite the pending job and leaves the look reading the remaining current project. Existing look checks retain rendering cancellation,
  session isolation and early line release.
- Reverse verification restores only the old queue-before-timer routing order and runs scripts/check-look-jobs.sh: the
  same five assertions turn red again; the router timer wiring guard also exits nonzero. The repaired router is restored
  byte for byte. Run scripts/check-local.sh look-jobs, including all scans.
- These are real App objects and the real queueKeys / execute / tool path after authorization. They do not exercise the
  account/license gate or live helper transport. The slow new_project predecessor is controlled; close_project executes through
  the actual router. The manual helper checklist remains required.

## Lessons

A response deadline must include every await in the authorized route, including the wait needed to discover its target.
Do not bind a target early to make a timer easier to start. The lasting queue, job and manual-helper rules are in
[the AI interface](../architecture/ai-control-mcp.md), items 3 / 12 / 46 and the manual regression checklist.

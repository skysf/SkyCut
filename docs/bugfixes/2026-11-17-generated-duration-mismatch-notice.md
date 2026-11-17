# 2026-11-17 Generated media omitted its requested duration and mismatch notice

## Symptom

MCP-9 reported a 76-second music request delivered as 73.4 seconds, and later music requests
returned several times their requested length. `get_job` did not show the requested and
returned lengths together or warn about their difference. On the current main code,
`SkyStudioGenerationRun.succeed` copied only `result.duration`; a later original-job refresh
updated only `remote_result`. Neither path compared the result with the submitted duration.

## Root cause

The normalized request duration remained in `generation.params`, but result reporting never
used it. Returning the provider's duration alone gave callers no explicit comparison and
made a short or unexpectedly long delivery look ordinary. A missing provider duration also
needed to remain unknown rather than being filled from the request.

## Fix

`SkyStudioGenerationDuration` reports `requested_duration` beside `duration` and adds
`duration_warning` when their absolute difference is greater than 1 second. Both shorter
and longer results use the same rule. The existing result duration is the only actual-length
source; automatic requests and missing or invalid results stay null. Unknown result length
is explained by `duration_note`. Images have no duration report.

`SkyStudioGenerationRun.finish` and `refreshOriginal` both use this projection. Explicit null
values clear stale duration warnings during refresh. This is a reporting change only: it
does not alter files, requests, timeline state, billing, undo history, or paid job submission.
The generate_media guide describes the fields without expanding the MCP catalog.

## Verification

- `GenerationDurationChecks` exercises the real projection with 76 → 73.4 seconds, 20 → 123.6
  seconds, a longer sound effect, exactly 1-second differences, differences just above that
  threshold, automatic music, missing and invalid actual lengths, invalid requested lengths,
  refresh replacement and warning clearing, and images.
- `checks/sky-studio-wiring.sh` requires the projection in terminal completion and refresh;
  reverse verification removes each production call in turn and requires a failing exit.
- The positive suite passed all 7,738 Sky Studio checks. Temporarily returning only the old result duration made 47 of those
  checks fail, including the 76 → 73.4 comparison, unknown-duration values and warning clearing; the production helper was
  then restored byte for byte.
- No real Sky Studio request, model, credit, keychain access, or private media is used.

## Lessons

Request duration is a target, not evidence of delivered length. Keep both values available,
apply mismatch notices in every result path, and preserve unknown values. This SkyCut fix
uses only the result duration already carried by Sky Studio; measuring or correcting that
server field and detecting silence within a file remain outside this change. The lasting
contract is in [Sky Studio jobs](../architecture/sky-studio-jobs.md#generated-duration-notices).

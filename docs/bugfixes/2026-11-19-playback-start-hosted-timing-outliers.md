# 2026-11-19 Hosted playback outliers blocked unrelated changes

## Symptom

The playback-start step failed on main and on #507. At a cut in #507, the initial audio and picture offset was
15.5 ms, then the first paired follow-up measured 1,364.8 ms of skew at 1,980.2 ms after the first picture. The
other four cut trials were within 20 ms. A shard also exhausted its 30 minutes while the existing preview
performance check was still running. [Main run](https://github.com/skysf/SkyCut/actions/runs/44489035493).
[First #507 samples](https://github.com/skysf/SkyCut/actions/runs/44487715508/artifacts/14511856729).

## Root cause

#507 already showed the failure on the #502 base, before #509 and #511. Those two merges touched the AI input
and tool paths, which the graphical check does not use. #506, #508 and #510 were already included in the #502
merge. They changed Quit, exclusive placement and shared AI instructions. The same graphical probe on the
green #502 PR had a 935.1 ms idle follow-up outlier in one launch. On the #507 rerun, all five cut follow-ups
were again within 21 ms. The differing failures on repeated runs point to sampling and scheduling variability.
[Green #502 samples](https://github.com/skysf/SkyCut/actions/runs/44479258634/artifacts/14509238313).
[Second #507 samples](https://github.com/skysf/SkyCut/actions/runs/44487715508/artifacts/14515330440).

The old checker required a complete five-launch batch with each individual sample in budget. A late follow-up
could turn an otherwise measured start into a missing trial. The confirmation rule also failed a scenario if
both batches contained an outlier, and could add five more launches to an already long shard.

## Fix

The probe records startup before waiting for the one-second pair and measures display callback cadence separately.
The gate requires median timings, at least half of whole launches within the existing per-launch budgets, and
structural checks on every launch. One bounded hosted confirmation adds three launches to the original five.
A missed follow-up ranks as the worst observation, and missing onset or a repeat timeout fails. The warm-start
display control caps the confirmation margin on onset. Shard 1 has five additional minutes for the two graphical
steps, with a four-minute deadline for this benchmark. The other shards still have 30 minutes.

## Verification

The normal wiring check runs `checks/PlaybackStart/test_compare.py`. Its cases include two isolated stalls, three
late trials, all five original cold starts over budget followed by good retries, missing onset, extra builds, a
follow-up timeout, and the unchanged one-second median limit.

## Lessons

Keep late samples, timeouts and first-stream acquisition visible. A repeat contributes evidence to the original
batch under the [playback-start contract](../architecture/playback-start.md).

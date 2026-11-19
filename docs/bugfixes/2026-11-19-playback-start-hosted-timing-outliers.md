# 2026-11-19 Hosted playback outliers blocked unrelated changes

## Symptom

After #502 merged, the playback-start step failed in every CI run that included it: main's run on `4f60b09b` and
ten attempts on #507 and four other branches, while #502's own run had passed. On main, cold open failed in three of
five launches. One launch had a 163.8 ms start skew against a 150 ms limit, and another a 233.9 ms one-second skew
against 45 ms. In a third, the picture appeared 1.1 s after the sound. Near-end and middle each had one launch at
66–92 ms of start skew. On #507 the cut's picture was 1,364.8 ms behind its sound at the one-second sample. Shard 1
also reached its 30-minute limit during the preview performance step. [Main run](https://github.com/skysf/SkyCut/actions/runs/44489035493).
[Main samples](https://github.com/skysf/SkyCut/actions/runs/44489035493/artifacts/14512853021).

## Root cause

The play path did not regress. Between the tree #502's green run tested (`04c79320`) and main, #508, #510, #509
and #511 merged. They changed Save As placement, AI tools and MCP text, none of which runs at launch, project open
or Play. The 55 hosted launches after the merge, from 11 runs, matched the 15 before it for warm start, middle, cut
and idle wake. The two scenarios that preroll after Play were slower: the median cold-open first audio went from
925 to 1,174 ms, and the end-replay start skew from 7 to 18 ms. Those runs also rebuilt for 148–213 s just before
the step, because main had saved no cache since #506, against 71 s for #502.

The gate had been calibrated in one favourable window. Its per-launch budgets came from the first 15 hosted
launches, and every launch had to meet them. In the 55 launches, 24% of cold opens and end replays and 2–11% of
the other scenarios missed a per-launch budget, so a five-launch batch passed less than 1% of the time. The old
repeat rule only rescued single small failures. Five median budgets sat inside the runner's own spread: cold-open
onset gap and start skew, and end-replay first audio, first picture and start skew.

The first launch of each fresh build was the noisiest. Two of the three cold-open failures happened there: a
picture frozen at frame 0 for 4.5 s while sound played, and a picture that stopped advancing after one second. The
same process recovered within seconds, with warm-start skews of 219 and 253 ms and later scenarios in sync. The M1
showed none of this in five launches.

A follow-up exactly one second after the first picture can come out as 999.9999999999432 ms after subtracting host
times. The checker treated that as a structural error, which fails without confirmation. It happened once in 385
launch scenarios.

#517 as first pushed required half of the launches in budget plus the medians, with a display-interval margin on
confirmation. A bootstrap of that rule over the 55 launches was still red in 45% of runs.

## Fix

- `scripts/check-playback-start.sh`: the first launch is an unscored warm-up that runs the same scenarios. It may
  fail or hang without failing the step, and its start skews appear in the summary. Each launch log records the
  load average.
- `checks/PlaybackStart/compare.py`: an onset gap or start skew of 500 ms or more, or a missed one-second follow-up,
  is a gross stall. None may occur in the first five launches, and at most one per scenario across all eight after
  confirmation. Confirmation no longer adds a margin. A median budget may not exceed its per-launch budget. A follow-up
  1e-6 ms short of a second still counts as one second.
- `checks/PlaybackStart/budgets.json`: cold-open medians move from 150 to 170 ms for onset gap and from 120 to
  145 ms for start skew. End-replay medians move from 190 to 220 ms for first audio and from 250 to 300 ms for first
  picture, with a 380 ms per-launch picture limit instead of 310 ms. End-replay start skew gets 48 ms median and
  60 ms per launch instead of the shared 34 and 45 ms. Every other limit is unchanged.
- `.github/workflows/checks.yml`: the step has 6 minutes and shard 1 has 40.
- #517 also split onset from the one-second follow-up in the probe and recorded the display cadence. Both stay.

## Verification

- A bootstrap over the 44 scored hosted launches is red in 3% of runs.
- `checks/PlaybackStart/test_compare.py` keeps the recorded pre-fix hosted samples red even with three healthy
  confirmation launches. In the bootstrap, Play delayed by 100, 200 or 350 ms is always red. A picture 300 ms
  late in every cold open is always red. A picture 1 s late in a quarter or half of the cold opens is red in 64% or
  95% of runs. [Pre-fix samples](https://github.com/skysf/SkyCut/actions/runs/44446600269/artifacts/14494172744).
- Removing the rounding tolerance or the stall rule turns the tests red. Allowing two stalls, raising the cold-open
  onset-gap median to 250 ms or accepting a quarter of the launches also turns them red.
- With a stub editor under `/bin/bash` 3.2, a warm-up that exits 1 or hangs does not stop the step, and the hang is
  killed. A scored launch that fails stops the step. A scored launch that exits non-zero still fails, so removing
  the #499 fix keeps the step red as before.

## Lessons

- Calibrate a hosted timing gate on several runs' launches. Before merging, compare each median budget with the
  spread of resampled medians.
- Tolerate isolated noise by count and keep a hard ceiling on gross failures. Keep the recorded failure as test data
  so a budget change cannot let it through.
- Leave the first launch of a fresh CI build unscored but visible. The rules and the update procedure are in
  [Playback start](../architecture/playback-start.md).

# Code review rounds

> What it covers: who checks each round of a change (Codex or the coordinator), how a fix round is classified, when real
> smoke tests run, what each round records, and how this policy is judged later.
> What it does not cover: how to run a smoke (the [GUI smoke procedure](gui-smoke-testing.md) and each smoke's brief), or
> merging (AGENTS.md "合并与分支" and the merge slot in [Build and packaging](../build/build-and-packaging.md)).
> User, 2026-11-24: chose review rounds by risk (「按风险分 (Recommended)」), to be indexed in AGENTS.md and evaluated later.
> The numbers behind the choice, and the time per round before it: [baseline report](../reports/2026-11-24-review-rounds-baseline.md).

## 1. Words

- **Change**: one task's PRs, reviewed together (IMG1 was Sky Studio #262 and SkyCut #550 in one review). Changes in SkyCut
  and in Sky Studio follow this doc alike, as the baseline's did.
- **Round**: what one check looks at. The first round is the change as first offered for review; a fix round is what is
  pushed to answer a check's findings. A follow-up push before the next check stays in the same round.
- **The coordinator**: the session that directs the workers (the Master session in 2026-11). It launches the reviews and
  smokes and reads diffs; it does not write the fixes.

## 2. The rules

1. **First round: Codex.** Codex reviews the first round of every change, read-only (since 2026-11-23 gpt-6.2-astra at max
   effort). Exception: a docs-only change (Markdown only: `docs/`, AGENTS.md, README) is wording, and the coordinator reads
   its diff instead. DOC1, the change that wrote this doc, went that way.
2. **Real smokes.** A change that reaches paid providers, the network or production also gets a real smoke test on what
   landed, whatever its reviews found. Ops runs it as SMK1–SMK3 did: Sky Studio's test account, a spend cap in the brief,
   and everything changed for the run restored and read back.
3. **Fix rounds by risk.** A fix round goes back to Codex only when it touches money (charging, refunds, credits,
   settlement) or anything that can lose or overwrite data (section 3). Every other fix round, such as one that touches only
   wording, messages, checks / tests or UI, is checked by the coordinator reading the diff.
4. **Codex only reviews.** It reports issues and never edits code, tests included (user, 2026-11-19); the change's author
   fixes them.
5. **The label waits for the check.** A PR whose round is waiting for a check stays without the `merge-slot` label and gets
   it once the check clears it (Codex's verdict "merge", or the coordinator's read). The brief says who adds the label.

## 3. Classifying a fix round

- **Who and when**: the coordinator, before the round is checked, from the fix diff itself (files and hunks), not from the
  commit messages or the author's summary.
- **Money**: the diff changes what is quoted, reserved, charged, refunded or settled, credit balances or their log, spend
  caps, or whether a job is charged at all (a check before charging counts). In SkyCut for example `SkyStudioJobRun`,
  `SkyStudioSpendStore`, `SkyStudioVoiceLibraryOrders`; in Sky Studio billing, refunds, the credit log and job settlement.
- **Data**: the diff changes code that writes, moves, renames or deletes
  - the user's files (projects, saved versions, media, exports, recordings), or picks a name that could replace one
    (`ProjectFileWriter`, `ProjectVersionStore`, `ExportFileName`, `ExclusivePlacement`, `EncodeQueue`,
    `ScreenRecordingFileCommit`);
  - database rows that hold a job's or a user's state, migrations included.
- **In doubt, it is money or data.** A round that touches money or data anywhere counts as a whole, however small the
  rest of it is.
- The classification and one line why go into the log (section 5) before the round is checked.

## 4. What each round records

| Check | Records | Where |
| --- | --- | --- |
| Codex review | the commit reviewed and its base, each finding with file:line, the verdict "merge" or "fix first" | its report, as the review lanes write it (`impl-briefs/status/CX<id>-<topic>.md` on the coordinator's Mac) |
| Coordinator's read | the commit read, the classification and why, what the read found (or "nothing"), the verdict | its line in the log (section 5) |
| Real smoke | steps and results, spend against the cap, what only the smoke could find, what was restored | its report, as SMK1–SMK3 (`impl-briefs/status/SMK<id>-<topic>.md`) |

The coordinator gives each finding one severity:

- **Serious**: money (a wrong charge, refund, credit or settlement), data lost or overwritten, a regression of something
  that works on main, a limit or check that does not hold before charging, or a result the provider or the user cannot use.
- **User-visible**: a wrong, missing or untranslated message, a wrong next step for the AI, or guide text that misstates
  what happens.
- **Edge**: wrong behaviour that needs unusual conditions (a file replaced mid-upload, a stalled answer, a redirect, a
  fallback model missing a field).
- **Guard**: a missing regression check, a check that stays green with its fix removed, or a flaky check.

One finding is one point or bullet the reviewer asks to fix: its sub-points stay one finding, and confirmations ("OK") do
not count. Findings count whether they are fixed in the change or go to the coordinator's backlog
(`impl-briefs/BUG-BACKLOG.md`). The baseline report is counted this way.

## 5. Evaluation

**The log.** The coordinator keeps one entry per change in `impl-briefs/review-rounds-log.md`, on its Mac next to the review
reports, so parallel PRs never collide on it. It writes the entry when the change merges and adds to it whenever something
is found later. An entry holds:

- the change and its PRs;
- per round: first or fix, who checked it (the Codex lane or the coordinator), a fix round's classification and why, the
  findings by severity, and four times: head committed, check launched, verdict, next push or merge;
- the later findings (item 2 below).

**What is measured per change:**

1. Findings per round by severity, kept apart for Codex first rounds, Codex fix rounds and coordinator reads.
2. Later findings: anything a smoke, a later review, the user or anyone else finds in the change after its last check. For
   each: its severity, whether it is money or data, which round's diff brought it in or left it, and, when that round was a
   coordinator read, the coordinator's judgement whether a Codex review of that round would likely have caught it, with one
   line why (in the round's own diff: likely; needs a live provider: no).
3. Hours per round, in three parts: the wait (head committed → check launched), the check (launched → verdict) and the fix
   (verdict → next push); a last round runs from its head to the merge. Commit and merge times come from GitHub, launch and
   verdict times from the review files or the log. The parts are kept apart because in the baseline most of a round's hours
   were the wait and the fix, not Codex's own run (the report's section 4).

**Going back at once.** If a fix round that the coordinator read instead of Codex lets a money or data issue through, found
by anyone at any time, the coordinator goes back to "Codex reviews every round" at once, notes it in the log and tells the
user. It does not wait for the revisit point.

**The revisit point**: after 15 changes merged under this policy (docs-only ones not counted) or on 2026-12-15, whichever
comes first. The coordinator tallies the log against the baseline: findings per round by severity, later findings that a
skipped review would likely have caught and how serious they were, and hours per round with and without a Codex review. A
docs PR adds the tally and a recommendation to the baseline report as a dated section. The user decides whether to keep,
change or drop the policy, and this doc follows.

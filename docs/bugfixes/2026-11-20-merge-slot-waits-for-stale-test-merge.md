# 2026-11-20 The merge slot waited forever on GitHub's stale test merge

## Symptom

- The merge slot's first real pull request (#527, labeled on 2026-11-19 at 19:23 UTC) had a green `check-all` at
  19:50. The slot neither merged it nor started a test run: its job kept polling and the PR stayed in the queue.
- Main had moved at 19:35: someone merged #521 by hand. Twenty minutes later GitHub still answered for #527
  `mergeable: true` with a `merge_commit_sha` whose first parent was the old main (b6d264df), not 685c5d80.

## Root cause

- The slot took GitHub's test merge commit of the pull request (`merge_commit_sha`, `refs/pull/N/merge`) as the
  tree to test. It waited until that commit's parents were the current main and the head.
- GitHub recomputes the test merge when the pull request receives new commits. It does not recompute it when the base
  branch moves, and reading the pull request through the REST API didn't make it. The REST docs say as much: "Each time
  the pull request receives new commits, GitHub creates a merge commit".
- So whenever main moved after a PR's last push, which is the usual case with several lanes merging, the slot waited
  for a commit that never came. The in-memory GitHub in `checks/MergeSlot/FakeGitHub.py` recomputed the test merge
  whenever the PR was read. The fake modeled a GitHub that doesn't exist, so the checks were green.

## Fix

- `scripts/merge-slot.py` builds the test merge itself:
  - it points `merge-slot/pr-<N>` at the current main;
  - it merges the head into it with the Merges API (`POST /repos/{owner}/{repo}/merges`), so the parents are (main,
    head) and the tree is GitHub's own merge;
  - a 409 means a conflict and sends the PR back, as before;
  - it builds this once per main and head: a later pass reuses the branch while its parents still match.
- GitHub's `mergeable` and `merge_commit_sha` are no longer read. Markers are still matched by tree, so the PR's own
  run still counts when main hasn't moved.
- The fake now behaves like GitHub: the test merge isn't recomputed when main moves, and `POST /merges` exists. A
  merge's tree is named by both sides' trees, so a different main or head is a different tree.

## Verification

- New scenario in `checks/MergeSlot/MergeSlotChecks.py`. The PR's own run is green; main moves; GitHub's test merge
  stays stale. The slot must test main + head itself (one test merge, not one per pass) and merge.
- With main's pre-fix script it's red, four failures: this scenario, and the two last-second races, which also relied on
  a fresh test merge. With the fix: 82 cases green.
- 23 mutations of the script each turn the checks red. The new ones: reuse a test merge for another main or head, and
  rebuild it every pass. A slot-run marker on other parents is now a case too.
- On GitHub: #527 goes through the slot again after this fix (status in the coordinator's CI2 report).

## Lessons

- A fake must copy the platform's quirks, not its documentation's happy path. Read what the platform promises (here
  "new commits"), and model only that.
- Build the artifact you test yourself when the platform's own copy is refreshed on its schedule, not yours. The
  long-term rule is in [Build and packaging "Merge slot"](../build/build-and-packaging.md).

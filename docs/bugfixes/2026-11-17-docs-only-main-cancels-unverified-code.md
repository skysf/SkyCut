# 2026-11-17 A docs-only merge cancels the only run checking an earlier code merge

## Symptom

A code PR merges after main has moved, so its actual merged tree differs from the tree its green PR run checked.
Before its main run finishes, a docs-only PR merges and cancels it. The docs-only run performs scans, or reuses its
own scan-only PR marker, leaving the earlier merged code untested. Replaying 141 main runs from November 4–17 found
two such gaps, around PRs #359 and #395.

## Root cause

Workflow concurrency correctly keeps only the newest main run, but both fast paths looked only at the newest merge.
Its first-parent diff can be docs-only even though its tree contains code inherited from a cancelled run. A green
docs-only PR marker proves that scans passed; it does not prove that the inherited code passed the full checks.

## Fix

- `scripts/ci-docs-only.sh` returns false on pushes. Docs-only PRs retain the scan-only fast path. Standard-input
  mode remains a pure path classifier so the verified-tree script shares the same whitelist.
- `scripts/ci-verified-tree.sh` rejects a docs-only or empty merge before looking for a PR marker. A docs-only main
  merge always runs all checks, including when its exact tree has a green scan-only PR marker.
- Code merges retain exact-tree reuse. Concurrency, PR grouping and the exemption for deliberate re-runs stay as
  before. The cost is a full main run for each docs-only merge; no ancestor/API bookkeeping is needed.
- The workflow comments and the canonical [CI and release contract](../build/build-and-packaging.md) describe the
  rule and retain the release fallback for commits using the earlier workflow.

## Verification

`checks/ci-verified-tree.sh` constructs a real code merge followed by a docs-only merge whose PR started before
concurrent code landed. It checks both workflow gates on a push, with a matching scan-only PR marker, without a
marker and with GitHub unavailable. Docs-only PRs still classify true; a code merge still reuses its fully checked
PR tree. The existing workflow scans require every heavy step to obey these gates.

Before the fix, the added guard exits 1 with two specific failures: the docs-only push selects scans and the
matching marker selects the verified-tree shortcut. After the fix, all 26 verified-tree cases and the docs-only
guard pass. Restoring each old production script separately makes its corresponding assertion fail; restoring
the fix returns the guard to green.

Local validation: `scripts/check-local.sh ci-docs-only ci-verified-tree docs-index-drift` (all scan guards and the
named checks). The PR's full CI is recorded in the task report.

## Lessons

Cancellation safety depends on what the replacement run actually verifies, not just whether its tree contains the
cancelled commits. Every shortcut needs evidence strong enough for the work it replaces. Keep this rule beside the
concurrency and fast-path definitions in the [CI contract](../build/build-and-packaging.md).

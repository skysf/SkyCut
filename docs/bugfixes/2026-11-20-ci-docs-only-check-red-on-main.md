# 2026-11-20 The docs-only check turned main red after a docs-only merge

## Symptom

Main's run after #532 (a docs-only PR the merge slot merged) went red on 2026-11-19: run 44626496956, the slot's
dispatch of `checks.yml` on 32e53b20. `checks/ci-docs-only.sh` failed in shard 5 with two of its own cases:

- "只加了 docs/b.md 的提交应该判 true";
- "合并提交带进来的只有文档（main 那边改的代码在第一个父提交里）应该判 true".

The same check passed on every pull request run and slot test before it. The code was fine; only main's color was wrong.
Every PR that comes after it reads main as red until a later run is green.

## Root cause

- The check's temp-repo cases run the classifier as a pull request's run would. `classify_repo` set
  `GITHUB_EVENT_NAME=pull_request` but left `GITHUB_REF` to whatever the run executing the check had.
- Since #526 (the merge slot), `scripts/ci-docs-only.sh` also treats `GITHUB_REF=refs/heads/main` as a main run (never
  docs-only), because the slot's dispatch on main is a `workflow_dispatch`, not a push.
- So on main, the "pull request" cases saw `GITHUB_REF=refs/heads/main` and got `false`.

Why it showed only now:

- PR runs (`refs/pull/N/merge`) and slot tests (`refs/heads/merge-slot/pr-<N>`) have other refs.
- Main runs for code merges take the verified short path and run no checks.
- Only a docs-only merge runs every check on main, and #532 was the first one since #526.

The case `classify_as` added with #526 sets both variables. The older helper next to it was never updated.

## Fix

`checks/ci-docs-only.sh`:

- Every pull-request case sets `GITHUB_EVENT_NAME=pull_request` and `GITHUB_REF=refs/pull/1/merge` itself, the temp-repo
  cases and the standard-input ones alike.
- New section 4: the check runs its own cases again as main's runs see them, a push and the slot's dispatch, both on
  `refs/heads/main`, and is red if any case changes its answer there. A case that inherits a GitHub variable now
  fails on every run, PRs included, not only on main.
- A push to main after a docs-only merge is a case of its own: `false`, so every check runs.

## Verification

- Before the fix, section 4 is red on a plain pull-request run. Run directly with `GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main`, the check prints exactly main's two failures.
- With the fix it is green with no GitHub variables, as a PR run, as a push on main, as the slot's dispatch on main, and
  as a slot test.
- Reverse verification: only the old `classify_repo` line put back, red on a plain pull-request run.
- `checks/ci-verified-tree.sh`, which tests the other main-run classifier, was already green under both main
  environments: its cases set both variables.

## Lessons

- A check of code that reads the CI environment must set every variable that code reads, in every case, and never
  inherit them from the run executing the check. When the code learns a new variable, every helper that calls it
  needs it too. The rule is in [build doc "CI"](../build/build-and-packaging.md), under the docs-only fast path.
- Main runs only some checks on some merges, so a bug that appears only on main can wait days. Make the check reproduce
  main's environment on every run, as section 4 does, instead of waiting for main to show it.

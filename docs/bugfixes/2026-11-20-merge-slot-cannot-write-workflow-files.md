# 2026-11-20 The merge slot called a workflow change a conflict

## Symptom

- After the first slot fix (#528), #527 went back into the slot. It removes a line from `.github/workflows/checks.yml`.
- Within seconds the slot sent it back: "it conflicts with main".
- There was no conflict. `git merge-tree` merged it cleanly, GitHub showed the PR `mergeable: clean`, and the same Merges
  API call made with a person's token succeeded (merge commit 9e51d5c9, parents: main and the head).

## Root cause

- The slot runs with the workflow token (`GITHUB_TOKEN`). GitHub doesn't let that token create or update files under
  `.github/workflows/`, and the workflow's `permissions:` can't grant it: there is no `workflows` permission for it.
  Community reports: [GitHub App tokens](https://github.community/t/refusing-to-allow-a-github-app-to-create-or-update-workflow-without-workflows-permission/182573),
  [the permission isn't available](https://github.community/t/workflows-vs-actions-which-permission-is-correct/178137).
- The slot's test merge writes a commit with the PR's workflow change onto `merge-slot/pr-<N>`. GitHub refused it with
  409, and the slot read every 409 as a conflict. Merging the PR with that token would be refused the same way.
- The slot was designed for code PRs. #528 touched no workflow file and the slot merged it; the first CI change sent
  through the slot hit the restriction.

## Fix

- `scripts/merge-slot.py` reads the PR's changed files (once per head). A PR that changes `.github/workflows/` leaves
  the slot at once, before any test merge, with the by-hand path: merge origin/main into the branch, push, and once
  `check-all` is green run `gh pr merge N --merge` at once.
- Any other 409 from the Merges API now quotes GitHub's own message in the comment.
- The rule is in AGENTS.md 「合并与分支」 and [Build and packaging "Merge slot"](../build/build-and-packaging.md).
- The fake (`checks/MergeSlot/FakeGitHub.py`) refuses workflow-file writes like the real token: 409 on the Merges API,
  403 on the PR merge.

## Verification

- New scenario in `checks/MergeSlot/MergeSlotChecks.py`: a workflow PR leaves with the by-hand path before any test
  merge, and the next PR goes on.
- It's red with main's script (the PR is called a conflict) and green with the fix (84 cases).
- Reverse verification: 24 mutations of the script each turn the checks red, including "workflow PRs not detected" and
  "conflict ignored".
- On GitHub: the PR with this fix goes through the slot itself (it changes no workflow file).

## Lessons

- A bot token isn't a person: list what it may not do on this platform before giving it a person's job, and test with
  the change it will meet most often in its own repository. Here that was CI changes, which the token can't write.
- Don't map an HTTP status to one meaning when the platform reuses it; show the platform's message.

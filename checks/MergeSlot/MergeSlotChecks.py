#!/usr/bin/env python3
"""Checks for the merge slot (scripts/merge-slot.py, .github/workflows/merge-slot.yml).

1. The slot against an in-memory GitHub (FakeGitHub.py): it merges only after a green checks run on the exact tree
   that lands (the pull request's own run while main hasn't moved, else its own test on merge-slot/pr-<N>), one at a
   time, oldest label first; red, conflicts, drafts, forks and refused merges leave the slot with a comment and the
   next pull request goes on; a human merge or a new head during a test means testing again, never merging.
2. The workflows' wiring: merge-slot.yml's triggers, one job-level slot that waits instead of cancelling, the token's
   permissions, main's script only (pull_request_target never checks out the pull request); checks.yml takes the
   slot's dispatches and skips every shard on a dispatch elsewhere, so check-all fails there.
Usage: python3 checks/MergeSlot/MergeSlotChecks.py   (no network, a few seconds)
"""
import datetime as dt
import importlib.util
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("merge_slot", os.path.join(ROOT, "scripts", "merge-slot.py"))
slot_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slot_module)
from FakeGitHub import FakeGitHub  # noqa: E402

FAILURES = []
CASES = 0


def check(name, condition, detail=""):
    global CASES
    CASES += 1
    if not condition:
        FAILURES.append(f"{name}: {detail}")


def world():
    gh = FakeGitHub(slot_module.GitHubError)
    return gh, slot_module.Slot(gh, now=lambda: gh.clock, sleep=gh.tick, log=lambda *_: None)


def serve(slot, gh, hours=6):
    slot.serve(gh.clock + dt.timedelta(hours=hours), poll=60)


def tested_trees(gh):
    """Trees a green checks run (pull request or slot) proved, by marker."""
    return {name[len("verified-tree-"):] for name in gh.markers}


def never_merged_untested(name, gh):
    check(name, not gh.overlaps, f"a second slot test started while another ran: {gh.overlaps}")
    proven = tested_trees(gh)
    for number, tree in gh.merged:
        check(name, tree in proven, f"#{number} landed tree {tree} that no green run tested")


# ---- 1. behaviour ----
gh, slot = world()
serve(slot, gh)
check("empty queue", not gh.dispatches and not gh.merged and not gh.comments, gh.calls)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)  # its own run tested main + head, and main hasn't moved
serve(slot, gh)
check("own run on the exact tree: merged at once", [n for n, _ in gh.merged] == [1], gh.merged)
check("own run on the exact tree: no slot test", "merge-slot/pr-1" not in gh.dispatches, gh.dispatches)
check("after a merge: checks.yml runs on main", gh.dispatches == ["main"], gh.dispatches)
check("after a merge: the branch is deleted", "topic-1" in gh.deleted, gh.deleted)
check("after a merge: a comment", any("merged" in c for c in gh.comments.get(1, [])), gh.comments)
never_merged_untested("own run", gh)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)
gh.human_merge()  # main moved after its run: its run no longer matches the landing tree
serve(slot, gh)
check("main moved: tested on merge-slot/pr-1 first", gh.dispatches[:1] == ["merge-slot/pr-1"], gh.dispatches)
check("main moved: then merged", [n for n, _ in gh.merged] == [1], gh.merged)
check("main moved: test branch deleted", "merge-slot/pr-1" in gh.deleted and "merge-slot/pr-1" not in gh.refs, gh.deleted)
never_merged_untested("main moved", gh)

gh, slot = world()
gh.open_pull(1, labeled_minutes=0)
gh.open_pull(2, labeled_minutes=1)
gh.outcomes["merge-slot/pr-1"] = "failure"
serve(slot, gh)
check("red test: #1 not merged, #2 merged", [n for n, _ in gh.merged] == [2], gh.merged)
check("red test: label removed", not any(l["name"] == "merge-slot" for l in gh.pulls[1]["labels"]), gh.pulls[1]["labels"])
check("red test: the comment links the run", any("example.invalid/runs/" in c and "failure" in c for c in gh.comments.get(1, [])), gh.comments)
never_merged_untested("red test", gh)

gh, slot = world()
gh.open_pull(1)
gh.outcomes["merge-slot/pr-1"] = "failure"
serve(slot, gh)
red = [r for r in gh.runs.values() if r["head_branch"] == "merge-slot/pr-1"][-1]["id"]
check("a red test keeps its branch for a re-run", "merge-slot/pr-1" in gh.refs, gh.refs)
gh.rerun_green(red)  # a known flake: the author re-runs the failed jobs, then labels again
gh.relabel(1)
serve(slot, gh)
check("a green re-run of the same test counts", [n for n, _ in gh.merged] == [1] and gh.dispatches.count("merge-slot/pr-1") == 1,
      (gh.merged, gh.dispatches))
never_merged_untested("re-run", gh)

gh, slot = world()
gh.open_pull(1)
gh.human_merge()
gh.lost_markers.add("merge-slot/pr-1")  # the test is green but its marker upload failed
serve(slot, gh)
check("a green test without its marker still counts", [n for n, _ in gh.merged] == [1] and gh.dispatches.count("merge-slot/pr-1") == 1,
      (gh.merged, gh.dispatches))
proven = tested_trees(gh) | {gh.commits[r["head_sha"]]["tree"] for r in gh.runs.values()
                             if r["head_branch"] == "merge-slot/pr-1" and r["conclusion"] == "success"}
check("…and it landed exactly the tree that run tested", all(t in proven for _, t in gh.merged), gh.merged)

gh, slot = world()
gh.open_pull(1)
gh.refs["merge-slot/pr-9"] = gh.main  # a closed pull request's test branch
gh.pulls[1]["labels"] = []
serve(slot, gh)
check("test branches of closed pull requests are swept", "merge-slot/pr-9" not in gh.refs, gh.refs)

gh, slot = world()
gh.open_pull(1, labeled_minutes=5)
gh.open_pull(2, labeled_minutes=1)
gh.open_pull(3, labeled_minutes=3)
gh.human_merge()  # all three need a slot test
serve(slot, gh)
check("oldest label first", [n for n, _ in gh.merged] == [2, 3, 1], gh.merged)
check("one at a time: every merge was tested on the main it landed on", len(gh.merged) == 3, gh.merged)
never_merged_untested("order", gh)

gh, slot = world()
gh.open_pull(1, workflow=True)  # 2026-11-19, #527: the workflow token can't write .github/workflows/
gh.open_pull(2, labeled_minutes=1)
serve(slot, gh)
check("a PR that changes .github/workflows/ leaves with the by-hand path, before any test merge",
      any("workflow" in c and "by hand" in c for c in gh.comments.get(1, [])) and gh.merges_made == 1, (gh.comments, gh.merges_made))
check("…and the next PR goes on", [n for n, _ in gh.merged] == [2], gh.merged)

gh, slot = world()
gh.open_pull(1, mergeable=False)
gh.open_pull(2, labeled_minutes=1, check="failure")
gh.open_pull(3, labeled_minutes=2, draft=True)
gh.open_pull(4, labeled_minutes=3, fork=True)
serve(slot, gh)
check("conflict, red head, draft, fork: none merged", not gh.merged, gh.merged)
check("a red head gets no slot test", not any(d.startswith("merge-slot/") for d in gh.dispatches), gh.dispatches)
for number, words in ((1, "conflicts"), (2, "check-all"), (3, "draft"), (4, "this repository")):
    check(f"#{number} left with a reason", any(words in c for c in gh.comments.get(number, [])), gh.comments.get(number))
    check(f"#{number} label removed", not gh.pulls[number]["labels"], gh.pulls[number]["labels"])

gh, slot = world()
gh.open_pull(1, check=None)  # its own run is still going
gh.open_pull(2, labeled_minutes=1)
def finish_first(g):
    if g.merged and g.checks[g.pulls[1]["head"]["sha"]][-1]["status"] != "completed":
        g.set_check(g.pulls[1]["head"]["sha"], "success")
gh.on_tick = finish_first
serve(slot, gh)
check("a pending head waits, the next one goes", [n for n, _ in gh.merged] == [2, 1], gh.merged)
never_merged_untested("pending head", gh)

gh, slot = world()
gh.open_pull(1)
def human_during_test(g):
    if "merge-slot/pr-1" in g.dispatches and len(g.dispatches) == 1:
        g.human_merge("tree-human")
gh.on_tick = human_during_test
serve(slot, gh)
check("human merge during the test: tested again", gh.dispatches.count("merge-slot/pr-1") == 2, gh.dispatches)
check("human merge during the test: merged on the new main", [n for n, _ in gh.merged] == [1], gh.merged)
never_merged_untested("human merge", gh)

gh, slot = world()
gh.open_pull(1)
def new_head(g):
    pull = g.pulls[1]
    if "merge-slot/pr-1" in g.dispatches and pull["head"]["ref"] == "topic-1" and not g.merged and len(g.dispatches) == 1:
        pull["head"]["sha"] = g.commit([g.main], "tree-head-1b")
        g.set_check(pull["head"]["sha"], "success")
        g.refresh(1)
gh.on_tick = new_head
serve(slot, gh)
check("new head during the test: tested again", gh.dispatches.count("merge-slot/pr-1") == 2, gh.dispatches)
check("new head during the test: the new head merged", gh.merged and gh.merged[0][1].endswith("+tree-head-1b)"), gh.merged)
never_merged_untested("new head", gh)

gh, slot = world()
gh.open_pull(1)
gh.add_run("pull_request", gh.pulls[1]["head"]["sha"], "topic-1", "failure", gh.commits[gh.pulls[1]["merge_commit_sha"]]["tree"],
           forced=True)
other = gh.commit([gh.main], "tree-head-x")
gh.add_run("pull_request", other, "topic-x", "success", gh.commits[gh.pulls[1]["merge_commit_sha"]]["tree"])
stale = gh.add_run("pull_request", gh.pulls[1]["head"]["sha"], "topic-1", "success",
                   gh.commits[gh.pulls[1]["merge_commit_sha"]]["tree"], created=gh.clock - dt.timedelta(hours=30))
odd = gh.commit([gh.main, other], "tree-odd")  # a slot run on other parents whose marker names this tree
gh.add_run("workflow_dispatch", odd, "merge-slot/pr-1", "success", gh.commits[gh.pulls[1]["merge_commit_sha"]]["tree"],
           forced=True)
serve(slot, gh)
check("markers from a red run, another head, a day-old run or a slot run on other parents don't count", gh.dispatches[:1] == ["merge-slot/pr-1"], gh.dispatches)
never_merged_untested("bad markers", gh)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)
gh.refuse_merge = 5
serve(slot, gh)
check("refused three times: leaves", not gh.merged and any("refused" in c for c in gh.comments.get(1, [])), gh.comments)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)
gh.race = True  # a human merges between the slot's read of the test merge and its merge
serve(slot, gh)
check("main moved in the last moment: tested again, then merged", [n for n, _ in gh.merged] == [1], gh.merged)
never_merged_untested("race", gh)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)
gh.human_merge(refresh=False)  # 2026-11-19, #527: GitHub's test merge stays on the old main after main moves
serve(slot, gh)
check("main moved and GitHub's test merge stayed stale: the slot tests main + head itself and merges",
      [n for n, _ in gh.merged] == [1] and gh.dispatches[:1] == ["merge-slot/pr-1"], (gh.merged, gh.dispatches))
check("one test merge per main and head, not one per pass", gh.merges_made == 1, gh.merges_made)
never_merged_untested("stale test merge", gh)

gh, slot = world()
gh.open_pull(1)
gh.pr_run(1)
gh.head_race = True  # a push lands between the slot's last read and its merge
serve(slot, gh)
check("a head pushed at the last moment is tested before it merges", [n for n, _ in gh.merged] == [1], gh.merged)
never_merged_untested("head race", gh)

gh, slot = world()
gh.open_pull(1)
gh.outcomes["merge-slot/pr-1"] = "cancelled"
serve(slot, gh)
check("a cancelled test is not green", not gh.merged and any("cancelled" in c for c in gh.comments.get(1, [])), gh.comments)

# ---- 2. the workflow ----
workflow = open(os.path.join(ROOT, ".github", "workflows", "merge-slot.yml"), encoding="utf-8").read()
code = "\n".join(line for line in workflow.splitlines() if not line.lstrip().startswith("#"))
for want, why in (
    (r"pull_request_target:\s*\n\s+types: \[labeled\]", "adding the label starts the slot"),
    (r"\n  workflow_dispatch:", "a manual start"),
    (r"\n  schedule:", "a safety net when an event is lost"),
    (r"\n    concurrency:\s*\n      group: merge-slot\s*\n      cancel-in-progress: false", "one job-level slot that waits, never cancels"),
    (r"if: github.event_name != 'pull_request_target' \|\| github.event.label.name == 'merge-slot'", "other labels don't start it"),
    (r"run: python3 -I -B scripts/merge-slot.py --repo", "the script"),
    (r"ref: main", "checks out main: pull_request_target never runs the pull request's code"),
):
    check(f"merge-slot.yml: {why}", re.search(want, code), want)
for forbidden in ("github.event.pull_request.head", "github.head_ref", "cancel-in-progress: true"):
    check(f"merge-slot.yml must not use {forbidden}", forbidden not in code, forbidden)
permissions = re.search(r"\npermissions:\n((?:  .*\n)+)", code)
granted = dict(re.findall(r"  ([a-z-]+): (\w+)", permissions.group(1))) if permissions else {}
check("merge-slot.yml permissions", granted == {"contents": "write", "pull-requests": "write", "issues": "write",
                                                 "actions": "write", "checks": "read"}, granted)

checks_yml = open(os.path.join(ROOT, ".github", "workflows", "checks.yml"), encoding="utf-8").read()
checks_code = "\n".join(line for line in checks_yml.splitlines() if not line.lstrip().startswith("#"))
check("checks.yml takes the slot's dispatches", re.search(r"\non:\n(?:  .*\n)*  workflow_dispatch:", checks_code), "on:")
check("checks.yml skips every shard on a dispatch elsewhere (check-all then fails)",
      "    if: github.event_name != 'workflow_dispatch' || github.ref == 'refs/heads/main' || "
      "startsWith(github.ref, 'refs/heads/merge-slot/pr-')\n    runs-on: macos-26" in checks_code, "the shard job's if")
check("the slot dispatches checks.yml by that name", 'WORKFLOW = "checks.yml"' in open(
    os.path.join(ROOT, "scripts", "merge-slot.py"), encoding="utf-8").read(), "WORKFLOW")

if FAILURES:
    for failure in FAILURES:
        print(f"✗ merge slot: {failure}", file=sys.stderr)
    sys.exit(1)
print(f"✓ merge slot: {CASES} cases (merges only a tree a green run tested, one at a time, oldest label first; red, "
      "conflicts, drafts, forks and refusals leave with a comment; workflow wiring)")

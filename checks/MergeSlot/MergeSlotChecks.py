#!/usr/bin/env python3
"""Checks for the merge slot (scripts/merge-slot.py, .github/workflows/merge-slot.yml).

1. The slot against an in-memory GitHub (FakeGitHub.py): it merges only after a green checks run on the exact tree
   that lands (the pull request's own run while main hasn't moved, else its own test on merge-slot/pr-<N>), one test
   at a time, oldest label first; red, conflicts, drafts, forks and refused merges leave the slot with a comment and the
   next pull request goes on; a human merge or a new head during a test means testing again, never merging.
   Batches (BatchCases.py, BatchLandingCases.py): ready pull requests tested together in one run; a green batch lands
   whole, in label order, or not at all (main rests on part of one only on the rare path a scenario injects on purpose);
   a red batch falls back to one at a time; any member or main changing mid-run cancels the run.
2. The workflows' wiring: merge-slot.yml's triggers, one job-level slot that waits instead of cancelling, the token's
   permissions, main's script only (pull_request_target never checks out the pull request); checks.yml takes the
   slot's dispatches and skips every shard on a dispatch elsewhere, so check-all fails there.
3. Runs GitHub's infrastructure failed (InfraRerunCases.py): scripts/ci-infra-rerun.py re-runs only those, never a
   check's failure; the slot waits for such a re-run instead of sending the pull request back; rerun-infra.yml's wiring.
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


def green_batches(gh):
    """Each green batch run, its members' numbers and its chain [(head, tree main must have right after that head
    merged)]. The chain is worked out here from the batch commit's parents (main, then the heads), not from the slot's
    own message; the numbers (only for the comments) come from the message."""
    found = []
    for run in gh.runs.values():
        if run["head_branch"] != "merge-slot/pr-batch" or run["conclusion"] != "success":
            continue
        commit = gh.commits[run["head_sha"]]
        tree, chain = gh.commits[commit["parents"][0]]["tree"], []
        for head in commit["parents"][1:]:
            tree = gh.merged_tree_of(tree, head)
            chain.append((head, tree))
        check("a batch commit's tree is main + its heads, merged in that order", tree == commit["tree"], commit)
        found.append((run, [int(n) for n in re.findall(r"^#(\d+) ", commit["message"], re.M)], chain))
    return found


def never_merged_untested(name, gh, partial=False):
    """After a scenario: never two tests at once; every landed tree tested. A green batch lands whole or not at all:
    one of its trees counts only when the batch landed from it to its end, and part of a batch only where the scenario
    breaks it on purpose (partial), where each member that didn't merge from it was told why. checks.yml is dispatched
    on main once after each landing (a single merge, the last of a batch's merges), never between a batch's merges."""
    check(name, not gh.overlaps, f"a second slot test started while another ran: {gh.overlaps}")
    proven, batches = tested_trees(gh), green_batches(gh)
    landed = [(gh.merged_heads.get(number), tree) for number, tree in gh.merged]
    for (number, tree), entry in zip(gh.merged, landed):
        mine = [(run, numbers, chain) for run, numbers, chain in batches if entry in chain]
        if tree in proven or any(all(e in landed for e in chain[chain.index(entry):]) for _, _, chain in mine):
            continue
        check(name, partial and mine, f"#{number} landed tree {tree}, which no green run tested"
              + (" (part of a batch: main rests on it)" if mine else ""))
        for run, numbers, chain in mine:
            for other, (head, other_tree) in zip(numbers, chain):
                if (head, other_tree) not in landed:
                    check(name, any(run["html_url"] in c or "refused the merge three times" in c
                                    for c in gh.comments.get(other, [])),
                          f"#{other} wasn't told why its batch {run['html_url']} stopped: {gh.comments.get(other)}")
    for at in range(len(landed)):
        within = at + 1 < len(landed) and any(chain[i:i + 2] == landed[at:at + 2]
                                               for _, _, chain in batches for i in range(len(chain) - 1))
        check(name, gh.main_after.count(at + 1) == (0 if within else 1),
              f"checks.yml dispatched on main {gh.main_after.count(at + 1)} times after #{gh.merged[at][0]} merged "
              f"({'between two merges of a batch' if within else 'want one'}): {gh.main_after}")
    check(name, 0 not in gh.main_after, f"checks.yml dispatched on main before anything merged: {gh.main_after}")


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
gh.breaking.add(gh.pulls[1]["head"]["sha"])  # #1 breaks the build: their batch is red, then each is tested alone
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
check("every merge landed what a green run tested", len(gh.merged) == 3, gh.merged)
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

# 2026-11-19 (#531, #532): an older PR's head turned green while a younger PR's slot test ran, and the slot tested it
# at once, since each pass started again from the oldest label. The PR under test holds the slot until its test ends.
gh, slot = world()
gh.slow_tests = 12  # a slot test takes 12 polls, longer than the 10-minute window, like a real one (13-16 min)
gh.list_delay = 2  # and GitHub lists it two polls late: the job remembers what it dispatched
gh.open_pull(1, check=None)  # its own run still going
gh.open_pull(2, labeled_minutes=1)
gh.human_merge()  # both need a slot test
def green_during_test(g):
    head = g.pulls[1]["head"]["sha"]
    if "merge-slot/pr-2" in g.dispatches and g.checks[head][-1]["status"] != "completed":
        g.set_check(head, "success")
gh.on_tick = green_during_test
serve(slot, gh)
check("an older PR turning green during a younger PR's test waits: one test at a time, the tested one merges first",
      not gh.overlaps and [n for n, _ in gh.merged] == [2, 1], (gh.overlaps, gh.merged, gh.dispatches))
never_merged_untested("older head green during a test", gh)

gh, slot = world()
gh.slow_tests = 12
gh.open_pull(1, check=None)
gh.open_pull(2, labeled_minutes=1)
gh.human_merge()
slot.serve(gh.clock + dt.timedelta(seconds=30), poll=60)  # dispatches #2's test, then the job's deadline passes
gh.set_check(gh.pulls[1]["head"]["sha"], "success")
fresh = slot_module.Slot(gh, now=lambda: gh.clock, sleep=gh.tick, log=lambda *_: None)  # the workflow's next job
serve(fresh, gh)
check("a new job of the workflow keeps the PR under test holding the slot (read from GitHub, not memory)",
      not gh.overlaps and [n for n, _ in gh.merged] == [2, 1], (gh.overlaps, gh.merged, gh.dispatches))
never_merged_untested("new job during a test", gh)

gh, slot = world()
gh.open_pull(1)
gh.open_pull(2, labeled_minutes=1)
gh.human_merge()
for number in (2, 1):  # two tests left running by a slot from before the fix; #2's started first
    merge_sha, _ = slot.test_merge(number, gh.main, gh.pulls[number]["head"]["sha"])
    gh.runs[gh.add_run("workflow_dispatch", merge_sha, f"merge-slot/pr-{number}", None)]["ticks_left"] = 12
    gh.tick(60)
serve(slot, gh)
check("two tests already running: the earlier holds and merges first, the other is tested again on the new main",
      [n for n, _ in gh.merged] == [2, 1] and gh.dispatches.count("merge-slot/pr-1") == 1, (gh.merged, gh.dispatches))
never_merged_untested("two tests left running", gh)

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

# ---- batches ----
import BatchCases  # noqa: E402
import BatchLandingCases  # noqa: E402
BatchCases.run_all(check, slot_module, world, serve, never_merged_untested)
BatchLandingCases.run_all(check, slot_module, world, serve, never_merged_untested)

# ---- 3. runs GitHub's infrastructure failed ----
import InfraRerunCases  # noqa: E402
InfraRerunCases.run_all(check, slot_module, world, serve, never_merged_untested)

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
print(f"✓ merge slot: {CASES} cases (merges only what a green run tested, one test at a time, oldest label first; "
      "ready PRs batched, up to four, and a green batch lands whole or not at all; a red batch falls back to one at a "
      "time; red, conflicts, drafts, forks and refusals leave with a comment; only GitHub's infrastructure failures are "
      "re-run, at most twice, never a check's; workflow wiring)")

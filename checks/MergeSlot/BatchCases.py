"""Batch cases for the merge slot (scripts/merge-slot-batch.py). MergeSlotChecks.py runs them with its check().

Ready pull requests are tested together, up to four, in one run on main + all of them (a commit whose parents are main
and their heads), and merge in label order only while main is exactly the tested chain up to the one before. A pull
request that conflicts with the ones before it waits (sent back only when it conflicts with main alone). A red batch
falls back to one test at a time from the oldest, so only the culprit is sent back. During a run, a member pushed,
unlabeled or closed, or main moved by a hand merge, never lets the stale result merge it or anything after it; when the
first member or main changed, the run is cancelled and the slot waits until it has stopped (never two test runs at
once). A new job carries on from what GitHub shows (the batch branch and its runs): mid-run, mid-merge, mid-fallback,
or a batch built but never dispatched. A single ready pull request takes the path from before batches.
"""
import datetime as dt

BATCH = "merge-slot/pr-batch"


def merged(gh):
    return [number for number, _ in gh.merged]


def batch_runs(gh):
    return sorted((r for r in gh.runs.values() if r["head_branch"] == BATCH), key=lambda r: r["id"])


def tests(gh):
    """The slot's test dispatches, in order (its runs on main left out)."""
    return [ref for ref in gh.dispatches if ref != "main"]


def members(gh, run):
    return gh.commits[run["head_sha"]]["parents"][1:]


def wait_exit(gh, number):
    """What scripts/merge-slot-wait.sh would answer now: 0 merged, 2 closed, 1 not in the slot (it prints the slot's
    last comment), 3 still in the slot."""
    pull = gh.pulls[number]
    if pull["merged"]:
        return 0
    if pull["state"] != "open":
        return 2
    return 3 if any(label["name"] == "merge-slot" for label in pull["labels"]) else 1


def sent_back(gh, number):
    return any("left the slot" in c for c in gh.comments.get(number, []))


def once_running(change):
    """A tick hook: change(gh) once, while a batch run is still going."""
    done = []

    def hook(gh):
        if not done and any(r["status"] != "completed" for r in batch_runs(gh)):
            done.append(True)
            change(gh)
    return hook


def push(gh, number, tree):
    pull = gh.pulls[number]
    pull["head"]["sha"] = gh.commit([gh.main], tree)
    gh.set_check(pull["head"]["sha"], "success")
    gh.refresh(number)


def unlabel(gh, number):
    gh.pulls[number]["labels"] = []


def run_all(check, slot_module, world, serve, never_merged_untested):
    def fresh(gh):  # the workflow's next job: nothing in memory, everything read from GitHub
        return slot_module.Slot(gh, now=lambda: gh.clock, sleep=gh.tick, log=lambda *_: None)

    def three(gh, count=3):
        for number in range(1, count + 1):
            gh.open_pull(number, labeled_minutes=number)
        return {number: gh.pulls[number]["head"]["sha"] for number in range(1, count + 1)}

    gh, slot = world()
    heads, main = three(gh, 2), gh.main
    serve(slot, gh)
    runs = batch_runs(gh)
    check("batch: two ready PRs are tested in one run", tests(gh) == [BATCH] and len(runs) == 1, gh.dispatches)
    check("batch: its commit's parents are main, then the heads in label order (checks.yml compares HEAD^1 = main)",
          runs and gh.commits[runs[0]["head_sha"]]["parents"] == [main, heads[1], heads[2]], runs)
    check("batch: both merged, in label order", merged(gh) == [1, 2], gh.merged)
    check("batch: main's tree after the last merge is the tree the run tested",
          runs and gh.commits[gh.main]["tree"] == gh.commits[runs[0]["head_sha"]]["tree"], gh.merged)
    check("batch: one run on main after the batch", gh.dispatches.count("main") == 1, gh.dispatches)
    check("batch: each member's comment names the run and the other member",
          all(any("merged after run" in c and f"#{other}" in c for c in gh.comments.get(n, [])) for n, other in ((1, 2), (2, 1))),
          gh.comments)
    check("batch: branches deleted (both topics, the batch branch)",
          {"topic-1", "topic-2", BATCH} <= set(gh.deleted) and BATCH not in gh.refs, (gh.deleted, gh.refs))
    check("batch: merge-slot-wait.sh exits 0 for both", [wait_exit(gh, n) for n in (1, 2)] == [0, 0], gh.pulls)
    never_merged_untested("batch of two", gh)

    gh, slot = world()
    gh.open_pull(1)
    gh.human_merge()
    serve(slot, gh)
    check("one ready PR: tested alone on merge-slot/pr-1, as before batches (no batch branch)",
          tests(gh) == ["merge-slot/pr-1"] and BATCH not in gh.created and merged(gh) == [1], (gh.dispatches, gh.created))
    never_merged_untested("one ready PR", gh)

    gh, slot = world()
    gh.open_pull(1)
    gh.open_pull(2, labeled_minutes=1, check=None)  # its own check-all is still running
    gh.on_tick = lambda g: g.set_check(g.pulls[2]["head"]["sha"], "success") if g.merged and not g.pulls[2]["merged"] \
        and g.checks[g.pulls[2]["head"]["sha"]][-1]["status"] != "completed" else None
    serve(slot, gh)
    check("one ready PR next to one whose check is still running: tested alone, as before batches",
          tests(gh) == ["merge-slot/pr-1", "merge-slot/pr-2"] and BATCH not in gh.created and merged(gh) == [1, 2],
          (gh.dispatches, gh.created))
    never_merged_untested("one ready PR next to a running check", gh)

    gh, slot = world()
    heads = three(gh, 4)
    gh.set_check(heads[2], None)  # still running
    gh.set_check(heads[3], "failure")
    gh.on_tick = lambda g: g.set_check(heads[2], "success") if 4 in merged(g) \
        and g.checks[heads[2]][-1]["status"] != "completed" else None
    serve(slot, gh)
    runs = batch_runs(gh)
    check("partners whose own check-all is red or still running don't join the batch",
          runs and members(gh, runs[0]) == [heads[1], heads[4]] and merged(gh) == [1, 4, 2], (gh.merged, gh.dispatches))
    check("…the red one is sent back with the usual comment when the slot gets to it",
          wait_exit(gh, 3) == 1 and any("check-all on the head" in c for c in gh.comments.get(3, [])), gh.comments)
    never_merged_untested("partners not ready", gh)

    gh, slot = world()
    gh.slow_tests = 3
    gh.open_pull(1)
    gh.open_pull(2, labeled_minutes=1, check=None)

    def ready_then_move(g):
        if any(r["head_branch"] == "merge-slot/pr-1" and r["status"] != "completed" for r in g.runs.values()) \
                and "tree-human" not in g.commits[g.main]["tree"]:
            g.set_check(g.pulls[2]["head"]["sha"], "success")
            g.human_merge("tree-human")
    gh.on_tick = ready_then_move
    serve(slot, gh)
    check("a PR's own test redone because main moved is redone alone, never batched while its old run goes",
          tests(gh) == ["merge-slot/pr-1", "merge-slot/pr-1", "merge-slot/pr-2"] and merged(gh) == [1, 2]
          and not gh.overlaps, (gh.dispatches, gh.overlaps))
    never_merged_untested("own test redone alone", gh)

    gh, slot = world()
    heads = three(gh)
    gh.pulls[2]["conflicts_with"] = {1}
    seen = {}
    gh.on_tick = lambda g: seen.setdefault("during", list(g.comments.get(2, []))) if batch_runs(g) else None
    serve(slot, gh)
    runs = batch_runs(gh)
    check("conflict with the one before it: a batch of #1 and #3", runs and members(gh, runs[0]) == [heads[1], heads[3]],
          [members(gh, r) for r in runs])
    check("…#2 waits without a comment while it conflicts only with #1", seen.get("during") == [], seen)
    check("…#1 and #3 merged", merged(gh) == [1, 3], gh.merged)
    check("…then #2 conflicts with main and is sent back with the usual comment",
          wait_exit(gh, 2) == 1 and any("conflicts with main" in c for c in gh.comments.get(2, [])), gh.comments)
    never_merged_untested("conflict inside a batch", gh)

    gh, slot = world()
    heads = three(gh)
    gh.pulls[2]["mergeable"] = False
    serve(slot, gh)
    runs = batch_runs(gh)
    check("conflict with main alone: sent back at once with the usual comment, #1 and #3 batched",
          merged(gh) == [1, 3] and any("conflicts with main" in c for c in gh.comments.get(2, []))
          and tests(gh) == [BATCH] and members(gh, runs[0]) == [heads[1], heads[3]], (gh.dispatches, gh.comments))
    never_merged_untested("conflict with main alone", gh)

    gh, slot = world()
    heads = three(gh)
    gh.breaking.add(heads[2])
    serve(slot, gh)
    check("red batch: falls back to one test at a time from the oldest",
          tests(gh) == [BATCH, "merge-slot/pr-1", "merge-slot/pr-2", "merge-slot/pr-3"], gh.dispatches)
    check("red batch: only the culprit is sent back, with the usual comment linking its own test",
          merged(gh) == [1, 3] and wait_exit(gh, 2) == 1
          and any("ended failure" in c and "left the slot" in c for c in gh.comments.get(2, [])), (gh.merged, gh.comments))
    check("red batch: the others are not blamed", not sent_back(gh, 1) and not sent_back(gh, 3), gh.comments)
    check("red batch: it costs one extra run (four tests for three PRs)", len(tests(gh)) == 4, gh.dispatches)
    never_merged_untested("red batch", gh)

    gh, slot = world()
    heads = three(gh)
    gh.breaking.add(heads[2])
    slot.serve(gh.clock + dt.timedelta(seconds=90), poll=60)  # the batch went red, #1 tested alone; then the deadline
    serve(fresh(gh), gh)
    check("red batch: the workflow's next job carries on one at a time (read from GitHub, no second batch)",
          tests(gh) == [BATCH, "merge-slot/pr-1", "merge-slot/pr-2", "merge-slot/pr-3"] and merged(gh) == [1, 3],
          (gh.dispatches, gh.merged))
    never_merged_untested("red batch, next job", gh)

    gh, slot = world()
    gh.slow_tests = 3
    heads = three(gh)
    gh.on_tick = once_running(lambda g: push(g, 2, "tree-head-2b"))
    order = []
    gh.after_merge = lambda g, n: order.append((n, len(batch_runs(g))))
    serve(slot, gh)
    check("a later member pushed mid-run: only the one before it merges from that run",
          order == [(1, 1), (2, 2), (3, 2)] and tests(gh) == [BATCH, BATCH], (order, gh.dispatches))
    check("…it and the one after it are tested again, its new head included",
          merged(gh) == [1, 2, 3] and gh.merged_heads.get(2) != heads[2]
          and not any("tree-head-2)" in tree for _, tree in gh.merged), gh.merged)
    never_merged_untested("member pushed mid-run", gh)

    gh, slot = world()
    gh.slow_tests = 3
    heads = three(gh)
    gh.on_tick = once_running(lambda g: push(g, 1, "tree-head-1b"))
    serve(slot, gh)
    first = (batch_runs(gh) or [{}])[0]
    check("the first member pushed mid-run: its run is cancelled, nothing merges from it",
          gh.cancels == [first.get("id")] and first.get("conclusion") == "cancelled" and tests(gh) == [BATCH, BATCH]
          and not any("tree-head-1)" in tree for _, tree in gh.merged), (gh.cancels, gh.dispatches, gh.merged))
    check("…the next batch waits until the cancelled run stopped, then merges all three",
          not gh.overlaps and not gh.redispatched and merged(gh) == [1, 2, 3], (gh.overlaps, gh.merged))
    never_merged_untested("first member pushed mid-run", gh)

    gh, slot = world()
    gh.slow_tests = 3
    heads = three(gh)
    gh.on_tick = once_running(lambda g: unlabel(g, 3))
    serve(slot, gh)
    check("the last member's label removed mid-run: the others merge from that run, it doesn't (and isn't blamed)",
          merged(gh) == [1, 2] and tests(gh) == [BATCH] and not gh.pulls[3]["merged"] and not gh.comments.get(3),
          (gh.merged, gh.dispatches, gh.comments))
    never_merged_untested("last label removed mid-run", gh)

    gh, slot = world()
    gh.slow_tests = 3
    heads = three(gh)
    gh.on_tick = once_running(lambda g: unlabel(g, 1))
    serve(slot, gh)
    check("the first member's label removed mid-run: its run is cancelled, the other two merge after a new batch",
          len(gh.cancels) == 1 and tests(gh) == [BATCH, BATCH] and merged(gh) == [2, 3] and not gh.overlaps,
          (gh.cancels, gh.dispatches, gh.merged))
    never_merged_untested("first label removed mid-run", gh)

    gh, slot = world()
    gh.slow_tests = 3
    heads = three(gh, 2)
    gh.on_tick = once_running(lambda g: g.human_merge("tree-human"))
    serve(slot, gh)
    check("main moved by a hand merge mid-run: the run is cancelled and nothing merges from it",
          len(gh.cancels) == 1 and tests(gh) == [BATCH, BATCH] and merged(gh) == [1, 2]
          and all("tree-human" in tree for _, tree in gh.merged) and not gh.overlaps, (gh.cancels, gh.merged))
    never_merged_untested("hand merge mid-run", gh)

    gh, slot = world()
    heads = three(gh)
    gh.after_merge = lambda g, n: g.human_merge("tree-human") if n == 1 and "tree-human" not in str(g.merged) else None
    serve(slot, gh)
    check("main moved by a hand merge between the batch's merges: the rest is tested again on the new main",
          merged(gh) == [1, 2, 3] and tests(gh) == [BATCH, BATCH] and not any("isn't the one" in c for c in gh.comments[1])
          and all("tree-human" in tree for n, tree in gh.merged if n != 1), (gh.merged, gh.dispatches))
    never_merged_untested("hand merge between merges", gh)

    gh, slot = world()  # no never_merged_untested here: #2 lands untested, the window every merge has (build doc)
    heads = three(gh)
    gh.after_merge = lambda g, n: setattr(g, "race_on_merge", 2) if n == 1 else None
    serve(slot, gh)
    check("a hand merge in the second before #2's merge: the slot sees main's tree differ and stops; #3 is tested again",
          merged(gh)[:2] == [1, 2] and any("isn't the one run" in c and "(#3)" in c for c in gh.comments.get(2, []))
          and tests(gh) == [BATCH, "merge-slot/pr-3"] and merged(gh) == [1, 2, 3], (gh.merged, gh.dispatches))

    gh, slot = world()
    three(gh, 6)
    serve(slot, gh)
    check("at most four in a batch: six ready PRs are tested as four, then two",
          [len(members(gh, r)) for r in batch_runs(gh)] == [4, 2] and merged(gh) == [1, 2, 3, 4, 5, 6],
          ([len(members(gh, r)) for r in batch_runs(gh)], gh.merged))
    never_merged_untested("cap", gh)

    gh, slot = world()
    gh.slow_tests = 12
    three(gh, 2)
    slot.serve(gh.clock + dt.timedelta(seconds=30), poll=60)  # dispatches the batch, then the job's deadline passes
    serve(fresh(gh), gh)
    check("the workflow's next job keeps the batch under test (its branch isn't swept) and merges from that run",
          tests(gh) == [BATCH] and merged(gh) == [1, 2] and not gh.overlaps, (gh.dispatches, gh.merged))
    never_merged_untested("next job mid-run", gh)

    class Stop(Exception):
        pass

    def stop_after_first(g, n):
        if n == 1:
            raise Stop()
    gh, slot = world()
    three(gh)
    gh.after_merge = stop_after_first
    try:
        serve(slot, gh)
    except Stop:
        pass
    gh.after_merge = None
    serve(fresh(gh), gh)
    check("a job that stopped between the batch's merges: the next one merges the rest from the same run",
          merged(gh) == [1, 2, 3] and tests(gh) == [BATCH] and gh.dispatches[-1] == "main", (gh.merged, gh.dispatches))
    never_merged_untested("resumed merges", gh)

    gh, slot = world()
    three(gh, 2)
    gh.fail_dispatch.add(BATCH)
    try:
        serve(slot, gh)
    except slot_module.GitHubError:
        pass
    built = gh.refs.get(BATCH)
    serve(fresh(gh), gh)
    check("a batch built but never dispatched (the job died): the next job dispatches that same commit",
          built and [r["head_sha"] for r in batch_runs(gh)] == [built] and merged(gh) == [1, 2],
          (built, [r["head_sha"] for r in batch_runs(gh)], gh.merged))
    never_merged_untested("built, never dispatched", gh)

    gh, slot = world()
    gh.slow_tests = 2
    three(gh, 2)
    slot.serve(gh.clock + dt.timedelta(seconds=30), poll=60)  # dispatched; the job stops before the run is done
    for _ in range(3):
        gh.tick(60)  # the run ends green
    gh.clock += dt.timedelta(hours=25)
    serve(fresh(gh), gh)
    check("a green batch run older than a day merges nothing: tested again",
          tests(gh) == [BATCH, BATCH] and merged(gh) == [1, 2], (gh.dispatches, gh.merged))
    never_merged_untested("day-old batch", gh)

    gh, slot = world()
    three(gh, 2)
    gh.outcomes[BATCH] = "infra"  # a shard never got a runner; its re-run is green
    serve(slot, gh)
    check("a batch run GitHub's infrastructure failed: re-run in place, then merged (no fallback)",
          merged(gh) == [1, 2] and tests(gh) == [BATCH] and gh.reruns == [r["id"] for r in batch_runs(gh)][:1],
          (gh.dispatches, gh.reruns))
    never_merged_untested("infra re-run", gh)

    gh, slot = world()
    three(gh)
    gh.after_merge = lambda g, n: setattr(g, "refuse_merge", 2) if n == 1 else None
    serve(slot, gh)
    check("GitHub refuses a member's merge twice: the batch stays and it merges on the third try",
          merged(gh) == [1, 2, 3] and tests(gh) == [BATCH], (gh.merged, gh.dispatches))
    never_merged_untested("refused twice", gh)

    gh, slot = world()
    gh.slow_tests = 400  # longer than the three hours a test may take
    three(gh, 2)
    gh.on_tick = lambda g: setattr(g, "slow_tests", 0) if g.cancels else None
    serve(slot, gh, hours=8)
    check("a batch run that hasn't finished in three hours is cancelled, then its members are tested alone",
          len(gh.cancels) == 1 and tests(gh) == [BATCH, "merge-slot/pr-1", "merge-slot/pr-2"] and merged(gh) == [1, 2]
          and not sent_back(gh, 1) and not sent_back(gh, 2), (gh.cancels, gh.dispatches, gh.merged))
    never_merged_untested("three hours", gh)

"""Landing cases for merge slot batches (scripts/merge-slot-batch.py, Batches.land). MergeSlotChecks.py runs them.

A green batch lands whole or not at all. Before its first merge every member is read again (open, not merged, labeled,
at its tested head, not a draft, a branch of this repository into main) and main must be the batch's base; else nothing
merges and the members wait again. A refused merge waits a poll; only refusals a poll apart count, and the third sends
the member back (before any merge, that drops the whole batch). A change in the seconds between two merges, or a third
refusal after one, is the one rare path that leaves main on part of a batch: the slot stops, checks.yml runs on main
once and each member that didn't merge is told why. checks.yml runs on main once per batch, never during a refusal
wait, and not again in the next job. An empty queue still finishes a batch off: main's run, the last comment, branches.
"""
import datetime as dt

from BatchCases import BATCH, batch_runs, merge_stamps, merged, next_job, open_pulls, push, tests, unlabel, wait_exit


def once_green(change):
    """A tick hook: change(gh) once, right after a batch run ended green and before the slot acts on it."""
    done = []

    def hook(gh):
        if not done and not gh.merged and any(r["conclusion"] == "success" for r in batch_runs(gh)):
            done.append(True)
            change(gh)
    return hook


def merged_by_hand(gh, number):
    """Someone merges the pull request outside the slot (not in gh.merged: that list is the slot's merges)."""
    pull = gh.pulls[number]
    made = gh.main = gh.commit([gh.main, pull["head"]["sha"]], gh.merged_tree(gh.main, pull["head"]["sha"]))
    pull.update(state="closed", merged=True, merge_commit_sha=made)


def refusals_apart(gh, seconds=60):
    """The refused merges are each at least a poll after the one before."""
    times = [when for _, when in gh.refused_at]
    return all(b - a >= dt.timedelta(seconds=seconds) for a, b in zip(times, times[1:]))


def told(gh, number, words):
    """The member got the rare path's comment: why its batch stopped, and main's full run."""
    return any("its batch stopped after" in c and words in c and "runs in full on main" in c
               for c in gh.comments.get(number, []))


def run_all(check, slot_module, world, serve, never_merged_untested):
    for what, change, after in (  # all or nothing: a change after the green run, before the first merge
            ("#3 pushed", lambda g: push(g, 3, "tree-head-3b"), [1, 2, 3]),
            ("#1 (the first) unlabeled", lambda g: unlabel(g, 1), [2, 3]),
            ("#2 made a draft", lambda g: g.pulls[2].update(draft=True), [1, 3]),
            ("#2 retargeted to another branch", lambda g: g.pulls[2]["base"].update(ref="release"), [1, 3]),
            ("#3 closed", lambda g: g.pulls[3].update(state="closed"), [1, 2]),
            ("#2 merged by hand", lambda g: merged_by_hand(g, 2), [1, 3]),
            ("#3's check-all re-run red", lambda g: g.set_check(g.pulls[3]["head"]["sha"], "failure"), [1, 2]),
            ("main moved by a hand merge", lambda g: g.human_merge("tree-human"), [1, 2, 3])):
        gh, slot = world()
        open_pulls(gh)
        gh.on_tick = once_green(change)
        stamps = merge_stamps(gh)
        serve(slot, gh)
        check(f"all or nothing: {what} after the batch's green run: nothing merges from that run, the rest is tested "
              "again", merged(gh) == after and stamps and min(stamps) >= 2 and not gh.cancels and BATCH not in gh.refs,
              (what, stamps, gh.dispatches, gh.merged))
        never_merged_untested(f"all or nothing: {what}", gh)

    gh, slot = world()
    open_pulls(gh)
    gh.on_tick = once_green(lambda g: (g.human_merge("tree-human"), merged_by_hand(g, 1)))
    stamps = merge_stamps(gh)
    serve(slot, gh)
    check("#1 merged by hand on a moved main isn't taken for the batch's own merge: nothing more merges from that run",
          merged(gh) == [2, 3] and min(stamps) >= 2, (gh.merged, stamps))
    never_merged_untested("merged by hand on a moved main", gh)

    gh, slot = world()  # the rare path: a member changes in the seconds between two merges
    heads = open_pulls(gh)
    gh.after_merge = lambda g, n: push(g, 2, "tree-head-2b") if n == 1 else None
    serve(slot, gh)
    check("#2 pushed between two merges: the batch stops after #1, #2 and #3 are told why and tested again",
          merged(gh) == [1, 2, 3] and gh.merged_heads[2] != heads[2] and tests(gh) == [BATCH, BATCH]
          and told(gh, 2, "#2 was pushed") and told(gh, 3, "#2 was pushed"), (gh.merged, gh.dispatches, gh.comments))
    check("…checks.yml runs on main right after the part that landed, once", gh.main_after == [1, 3], gh.main_after)
    never_merged_untested("pushed between merges", gh, partial=True)

    gh, slot = world()
    open_pulls(gh)
    gh.after_merge = lambda g, n: g.pulls[2].update(state="closed") if n == 1 else None
    serve(slot, gh)
    check("#2 closed between two merges never merges; #3 is told why and tested again",
          merged(gh) == [1, 3] and not gh.pulls[2]["merged"] and told(gh, 3, "#2 was closed"), (gh.merged, gh.comments))
    never_merged_untested("closed between merges", gh, partial=True)

    gh, slot = world()
    heads = open_pulls(gh)
    gh.after_merge = lambda g, n: setattr(g, "push_before_merge", 2) if n == 1 else None
    serve(slot, gh)
    check("a head pushed in the second before its merge: the pinned head is refused, the new one is tested first",
          merged(gh) == [1, 2, 3] and [n for n, _ in gh.refused_at] == [2] and tests(gh) == [BATCH, BATCH]
          and told(gh, 2, "#2 was pushed"), (gh.merged, gh.refused_at, gh.dispatches))
    never_merged_untested("pushed in the last second", gh, partial=True)

    gh, slot = world()
    open_pulls(gh)
    gh.after_merge = lambda g, n: setattr(g, "refuse_merge", 2) if n == 1 else None
    serve(slot, gh)
    check("GitHub refuses #2's merge twice: it waits a poll each time, then merges; checks.yml on main once, at the end",
          merged(gh) == [1, 2, 3] and tests(gh) == [BATCH] and len(gh.refused_at) == 2 and refusals_apart(gh)
          and gh.main_after == [3], (gh.merged, gh.refused_at, gh.main_after))
    never_merged_untested("refused twice", gh)

    gh, slot = world()
    open_pulls(gh)
    gh.after_merge = lambda g, n: setattr(g, "refuse_merge", 1) if n == 1 else None
    slot.serve(gh.clock + dt.timedelta(minutes=1), poll=60)  # #1 merges, #2 is refused; the job's deadline passes
    serve(next_job(slot_module, gh), gh)
    check("a new job during a refusal wait finishes the batch without a second comment on #1",
          merged(gh) == [1, 2, 3] and [sum("merged after run" in c for c in gh.comments.get(n, [])) for n in (1, 2, 3)]
          == [1, 1, 1] and gh.main_after == [3], (gh.merged, gh.comments, gh.main_after))
    never_merged_untested("new job during a refusal wait", gh)

    gh, slot = world()
    open_pulls(gh)
    gh.after_merge = lambda g, n: setattr(g, "refuse_merge", 3) if n == 1 else None
    serve(slot, gh)
    check("GitHub refuses #2 three times, a poll apart, after #1 merged: #2 is sent back, the batch stops there",
          merged(gh) == [1, 3] and wait_exit(gh, 2) == 1 and len(gh.refused_at) == 3 and refusals_apart(gh)
          and any("refused the merge three times" in c for c in gh.comments.get(2, [])), (gh.merged, gh.refused_at))
    check("…#3 is told why and tested alone; checks.yml on main once after #1, once after #3",
          told(gh, 3, "refused to merge #2 three times") and tests(gh) == [BATCH, "merge-slot/pr-3"]
          and gh.main_after == [1, 2], (gh.comments.get(3), gh.dispatches, gh.main_after))
    never_merged_untested("refused three times after a merge", gh, partial=True)

    gh, slot = world()
    open_pulls(gh)
    gh.on_tick = once_green(lambda g: setattr(g, "refuse_merge", 3))
    stamps = merge_stamps(gh)
    serve(slot, gh)
    check("GitHub refuses #1 three times before anything merged: #1 is sent back and nothing lands from that run",
          merged(gh) == [2, 3] and wait_exit(gh, 1) == 1 and min(stamps) >= 2 and tests(gh) == [BATCH, BATCH],
          (gh.merged, stamps, gh.dispatches))
    never_merged_untested("refused three times first", gh)

    gh, slot = world()
    open_pulls(gh)
    gh.after_merge = lambda g, n: setattr(g, "refuse_merge", 99) if n == 1 else None
    slot.serve(gh.clock + dt.timedelta(minutes=1), poll=60)  # #1 merges, #2 is refused once; the deadline passes
    for _ in range(3):  # tried again at once, three times
        slot.batches.step(slot.queue(), slot.dispatch_runs())
    check("refusals less than a poll apart count once: #2 keeps its place", wait_exit(gh, 2) == 3
          and len(gh.refused_at) == 4, (gh.refused_at, gh.comments.get(2)))
    gh.refuse_merge = 0
    serve(slot, gh)
    check("…and merges once GitHub lets it", merged(gh) == [1, 2, 3], gh.merged)
    never_merged_untested("refusals less than a poll apart", gh)

    gh, slot = world()
    open_pulls(gh, 2)
    gh.fail_delete.add(BATCH)  # the job dies deleting the batch's branch, after it dispatched main's run
    try:
        serve(slot, gh)
    except slot_module.GitHubError:
        pass
    serve(next_job(slot_module, gh), gh)
    check("a job that stopped after main's run: the next one deletes the batch's branch, no second run on main",
          merged(gh) == [1, 2] and gh.main_after == [2] and BATCH not in gh.refs, (gh.main_after, gh.refs))
    never_merged_untested("main's run once across jobs", gh)

    gh, slot = world()
    open_pulls(gh, 2)
    gh.fail_delete.add("topic-2")  # the job dies right after #2's merge, deleting its branch
    try:
        serve(slot, gh)
    except slot_module.GitHubError:
        pass
    stopped = (merged(gh), list(gh.main_after), BATCH in gh.refs, len(gh.comments.get(2, [])))
    serve(next_job(slot_module, gh), gh)  # nothing is labeled any more
    check("finished off on an empty queue: checks.yml on main, #2's comment and branch, the batch's branch",
          stopped == ([1, 2], [], True, 0) and gh.main_after == [2] and "topic-2" in gh.deleted
          and BATCH not in gh.refs and sum("merged after run" in c for c in gh.comments.get(2, [])) == 1,
          (stopped, gh.main_after, gh.deleted, gh.comments.get(2)))
    never_merged_untested("finished off", gh)

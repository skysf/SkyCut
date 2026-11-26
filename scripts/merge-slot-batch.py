"""Batches for the merge slot (scripts/merge-slot.py loads this file by path). When more than one labeled pull request
is ready, one checks run tests main plus all of them; a green batch lands whole, in label order, or not at all. The
rules are in docs/build/build-and-packaging.md "Merge slot"; checks/MergeSlot/BatchCases.py and BatchLandingCases.py
test this against a fake GitHub.

A batch lives on the branch merge-slot/pr-batch as one commit made for it:
- its tree is main + the first pull request + the second + ..., merged one after another with the Merges API;
- its parents are main and the members' heads in that order, so checks.yml classifies and measures it against main as
  it does a single pull request's test merge (scripts/ci-docs-only.sh and the preview perf ratchet compare with HEAD^1);
- its message lists each member's number, head and the tree main must have right after merging it.
Everything is read back from GitHub on every pass (the branch, that commit, the runs on the branch, the members and
their merge commits), so the workflow's next job carries on where this one stopped.
"""
import datetime as dt
import re

BATCH_REF = "merge-slot/pr-batch"  # checks.yml takes dispatches on main and merge-slot/pr-* only
BATCH_CAP = 4  # why four: build doc "Merge slot", "Batches"
LIST_DELAY = dt.timedelta(minutes=10)  # GitHub lists a dispatched run a little later
TITLE = "Merge slot batch:"
MEMBER = re.compile(r"^#(\d+) (\S+) (\S+)$")


def when(text):
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


class Batch:
    """A batch commit: its sha, the main it was built on, and its members [(number, head, tree after it)] in order."""

    def __init__(self, sha, base, members):
        self.sha, self.base, self.members = sha, base, members

    def message(self):
        numbers = " ".join(f"#{number}" for number, _, _ in self.members)
        lines = [f"{TITLE} {numbers} on main {self.base[:10]}", ""]
        return "\n".join(lines + [f"#{number} {head} {tree}" for number, head, tree in self.members]) + "\n"

    @classmethod
    def parse(cls, sha, commit):
        """The batch a commit holds (as GET commits/{sha} returns it), or None when it isn't one the slot made."""
        text = commit["commit"].get("message") or ""
        if not text.startswith(TITLE):
            return None
        members = [(int(m.group(1)), m.group(2), m.group(3))
                   for m in (MEMBER.match(line.strip()) for line in text.splitlines()[1:]) if m]
        parents = [p["sha"] for p in commit["parents"]]
        if (len(members) < 2 or parents[1:] != [head for _, head, _ in members]
                or len({number for number, _, _ in members}) != len(members)
                or members[-1][2] != commit["commit"]["tree"]["sha"]):
            return None
        return cls(sha, parents[0], members)


class Batches:
    """The slot's batch: forms it where the slot would test one pull request, holds the slot while its run goes, lands
    it whole when green, and after a red one has its members tested one at a time (Slot.serve calls step() every pass,
    and once more before it stops on an empty queue, so a batch is finished off)."""

    def __init__(self, slot, error, label, prefix, workflow, workflow_path, max_age, timeout):
        self.slot, self.gh, self.error = slot, slot.gh, error
        self.label, self.prefix, self.workflow, self.workflow_path = label, prefix, workflow, workflow_path
        self.max_age, self.timeout = max_age, timeout
        self.dispatched = {}  # batch commit -> when this job dispatched its run
        self.cancelled = set()  # runs this job asked GitHub to cancel
        self.verdicts = {}  # (run id, attempt) -> the final verdict on a red batch run
        self.commits = {}  # sha -> GET commits/{sha}: a commit never changes
        self.refusals = {}  # number -> (refused merges counted, when the last counted one was)
        self.settled = set()  # (batch commit, number): merged members whose branches and comment are done

    # ---- reading GitHub ----
    def commit(self, sha):
        if sha not in self.commits:
            self.commits[sha] = self.gh.call("GET", f"repos/{{repo}}/commits/{sha}")
        return self.commits[sha]

    def current(self):
        """The batch on merge-slot/pr-batch, or None."""
        try:
            sha = self.gh.call("GET", f"repos/{{repo}}/git/ref/heads/{BATCH_REF}")["object"]["sha"]
        except self.error as error:
            if error.status != 404:
                raise
            return None
        return Batch.parse(sha, self.commit(sha))

    def ready(self, pull):
        """The fresh pull request when it may join a batch now (green head, label on), else None. It never sends one
        back: the slot does that when it gets to it."""
        pull = self.gh.call("GET", f"repos/{{repo}}/pulls/{pull['number']}")
        if (pull["state"] != "open" or pull["draft"] or not any(l["name"] == self.label for l in pull["labels"])
                or pull["head"]["repo"]["full_name"] != pull["base"]["repo"]["full_name"] or pull["base"]["ref"] != "main"
                or self.slot.workflow_files(pull["number"], pull["head"]["sha"])):
            return None
        check = self.slot.head_check(pull["head"]["sha"])
        return pull if check and check[:2] == ("completed", "success") else None

    def unfit(self, pull, head):
        """Why a member can't land from its batch's run any more, or None. pull: a fresh read, or the queue's listing
        (which has no "merged": everything in it is open)."""
        number = pull["number"]
        if pull.get("merged") or pull["state"] != "open":
            return f"#{number} was " + ("merged some other way" if pull.get("merged") else "closed")
        if not any(label["name"] == self.label for label in pull["labels"]):
            return f"#{number} was unlabeled"
        if pull["head"]["sha"] != head:
            return f"#{number} was pushed"
        if pull["draft"]:
            return f"#{number} was made a draft"
        if pull["head"]["repo"]["full_name"] != pull["base"]["repo"]["full_name"] or pull["base"]["ref"] != "main":
            return f"#{number} no longer merges a branch of this repository into main"
        return None

    def changed(self, batch, pulls):
        """Why the batch can't land as its run tests it, from the queue (pulls: the waiting ones by number), or None."""
        for number, head, _ in batch.members:
            why = self.unfit(pulls[number], head) if number in pulls else f"#{number} was unlabeled, closed or merged"
            if why:
                return why
        return None

    def ours(self, pull, expected, member):
        """Whether this batch merged the member (on an earlier pass or in an earlier job): its merge commit's parents
        are (expected, the tested head) and its tree is the one the run tested."""
        _, head, tree = member
        sha = pull.get("merge_commit_sha") or ""
        if not (pull.get("merged") and sha):
            return False
        commit = self.commit(sha)
        return [p["sha"] for p in commit["parents"]] == [expected, head] and commit["commit"]["tree"]["sha"] == tree

    def green(self, run, batch):
        """A green checks run of this repository on the batch commit, under a day old."""
        own = run["repository"]["full_name"]
        return (run["path"] == self.workflow_path and run["event"] == "workflow_dispatch"
                and run["head_branch"] == BATCH_REF and run["head_sha"] == batch.sha and run["conclusion"] == "success"
                and (run.get("head_repository") or {}).get("full_name") == own
                and self.slot.now() - when(run["created_at"]) < self.max_age)

    def verdict(self, run):
        """The slot's verdict on a red batch run (re-running it when GitHub's infrastructure failed it), cached."""
        key = (run["id"], run.get("run_attempt"))
        if key not in self.verdicts:
            found = self.slot.retry(run["id"])
            kind = found.kind if found else "real"
            if kind in ("rerunning", "pending", "green"):
                return kind
            self.verdicts[key] = kind
        return self.verdicts[key]

    # ---- acting ----
    def dispatch(self, batch):
        self.gh.call("POST", f"repos/{{repo}}/actions/workflows/{self.workflow}/dispatches", {"ref": BATCH_REF})
        self.dispatched[batch.sha] = self.slot.now()
        self.slot.log(f"batch {' '.join(f'#{n}' for n, _, _ in batch.members)}: testing {batch.sha} on {BATCH_REF}")
        return "testing"

    def drop(self, batch, why):
        self.slot.log(f"batch {' '.join(f'#{n}' for n, _, _ in batch.members)} dropped: {why}")
        self.slot.drop_ref(BATCH_REF)

    def cancel(self, run):
        if run["id"] in self.cancelled:
            return
        try:
            self.gh.call("POST", f"repos/{{repo}}/actions/runs/{run['id']}/cancel", {})
        except self.error as error:
            if error.status != 409:  # 409: it has just ended
                raise
        self.cancelled.add(run["id"])
        self.slot.log(f"run {run['id']} on {BATCH_REF} cancelled: no batch needs it")

    def form(self, lead, base, lead_merge, partners):
        """Called where the slot would dispatch the lead's own test: one run on main + the lead + up to BATCH_CAP - 1
        ready partners, in label order, instead. A partner that conflicts with main alone leaves as usual; one that
        conflicts only with the members before it waits for the next batch. None when no partner joins: the lead is
        then tested alone, as before batches."""
        members, built = [(lead["number"], lead["head"]["sha"], lead_merge[1])], False
        for pull in partners:
            if len(members) == BATCH_CAP:
                break
            pull = self.ready(pull)
            if pull is None:
                continue
            if not built:  # the chain starts from the lead's own test merge (main + the lead)
                self.slot.point(BATCH_REF, lead_merge[0])
                built = True
            try:
                made = self.gh.call("POST", "repos/{repo}/merges", {
                    "base": BATCH_REF, "head": pull["head"]["sha"],
                    "commit_message": f"Merge slot test: #{pull['number']} after {' '.join(f'#{n}' for n, _, _ in members)}"})
            except self.error as error:
                if error.status != 409:
                    raise
                alone = self.slot.test_merge(pull["number"], base, pull["head"]["sha"])
                if isinstance(alone, tuple) and alone[0] == "conflict":
                    self.slot.conflict(pull, alone[1])
                else:
                    self.slot.log(f"#{pull['number']} conflicts with the batch before it: it waits for the next one")
                continue
            if made:  # 204: the batch so far already contains its head
                members.append((pull["number"], pull["head"]["sha"], made["commit"]["tree"]["sha"]))
        if len(members) == 1:
            if built:
                self.slot.drop_ref(BATCH_REF)
            return None
        batch = Batch(None, base, members)
        batch.sha = self.gh.call("POST", "repos/{repo}/git/commits", {
            "message": batch.message(), "tree": members[-1][2], "parents": [base] + [h for _, h, _ in members]})["sha"]
        self.slot.point(BATCH_REF, batch.sha)
        return self.dispatch(batch)

    def step(self, waiting, runs):
        """This pass's batch: "testing" while it holds the slot (its run goes, or a refused merge waits a poll),
        "merged" / "moved" when it acted, "fallback" while the members of a red batch are tested one at a time, None
        when there is no batch."""
        on_branch = [r for r in runs if r["head_branch"] == BATCH_REF]
        batch = self.current()
        own = [r for r in on_branch if batch and r["head_sha"] == batch.sha]
        run = max(own, key=lambda r: r["id"]) if own else None
        stray = [r for r in on_branch if r["status"] != "completed" and r is not run]
        for other in stray:  # a run no batch needs any more holds the slot until GitHub has stopped it
            self.cancel(other)
        if stray:
            return "testing"
        if batch is None:
            return None
        pulls = {pull["number"]: pull for pull in waiting}
        if run is None:
            return self.undispatched(batch, pulls)
        if run["status"] != "completed":
            return self.running(batch, run, pulls)
        if run["conclusion"] == "success":
            if self.green(run, batch):
                return self.land(batch, run, runs)
            return self.drop(batch, f"its green run {run['html_url']} no longer proves it (a day old?)")
        if self.verdict(run) in ("rerunning", "pending", "green"):
            return "testing"  # GitHub's own failure is being re-run: the slot stays held, as for a single test
        if any(number in pulls and pulls[number]["head"]["sha"] == head for number, head, _ in batch.members):
            return "fallback"  # each member still at the head it tested is tested alone, oldest first
        return self.drop(batch, f"its run {run['html_url']} ended {run['conclusion']} and each member is done")

    def undispatched(self, batch, pulls):
        sent = self.dispatched.get(batch.sha)
        if sent and self.slot.now() - sent < LIST_DELAY:
            return "testing"  # dispatched; GitHub lists the run a little later
        if self.changed(batch, pulls) is None and self.slot.main_sha() == batch.base:
            return self.dispatch(batch)  # built, never dispatched: the job before this one stopped in between
        return self.drop(batch, "it was never tested, and it changed since")

    def running(self, batch, run, pulls):
        if self.slot.now() - when(run.get("run_started_at") or run["created_at"]) > self.timeout:
            self.cancel(run)  # it ends cancelled; then its members are tested one at a time
            return "testing"
        why = self.changed(batch, pulls) or ("main moved" if self.slot.main_sha() != batch.base else None)
        if why:  # a batch lands whole or not at all, so its result can't land any more
            self.cancel(run)
            self.drop(batch, f"{why} while its run {run['html_url']} went")
        return "testing"  # held until the run ends, or until GitHub has stopped it

    def land(self, batch, run, runs):
        """A green batch lands whole, in label order, or not at all. Before its first merge every member is read again
        and must be exactly what the run tested, its check-all still green, and main its base; else nothing merges and
        the members wait again.
        Then each merges with its head pinned, only while main is the previous merge, and main's parents and tree are
        checked after it. A refused merge waits a poll. A change in the seconds between two merges, or a third refusal
        after one, stops the batch part-way: the one rare path (build doc "Merge slot", "Batches")."""
        pulls = [self.gh.call("GET", f"repos/{{repo}}/pulls/{number}") for number, _, _ in batch.members]
        expected, done = batch.base, 0
        while done < len(pulls) and self.ours(pulls[done], expected, batch.members[done]):
            expected, done = pulls[done]["merge_commit_sha"], done + 1  # merged on an earlier pass or by an earlier job
        if done:
            self.settle(batch, run, pulls[done - 1])
        else:  # nothing merged yet: all or nothing (main is checked before the first merge below)
            why = next(filter(None, (self.unfit(pull, head) for pull, (_, head, _) in zip(pulls, batch.members))), None)
            for number, head, _ in batch.members if why is None else ():
                if (self.slot.head_check(head) or ())[:2] != ("completed", "success"):
                    why = f"check-all on #{number}'s head isn't green any more"  # GitHub would refuse its merge
                    break
            if why:
                self.drop(batch, f"{why} since its run {run['html_url']}: nothing merges from it")
                return "moved"
        why, left = None, None
        for number, head, tree in batch.members[done:]:
            pull = self.gh.call("GET", f"repos/{{repo}}/pulls/{number}")
            why = self.unfit(pull, head)
            if why is None and self.slot.main_sha() != expected:
                why = "main moved through another merge"
            if why:
                break
            try:
                result = self.gh.call("PUT", f"repos/{{repo}}/pulls/{number}/merge", {"merge_method": "merge", "sha": head})
            except self.error as error:
                if error.status not in (405, 409):
                    raise
                if self.refused(pull, error) == "waits":
                    return "testing"  # the slot stays held; the next pass tries this member again
                why, left = f"GitHub refused to merge #{number} three times", number
                break
            self.refusals.pop(number, None)
            merged, done = (result or {}).get("sha") or self.slot.main_sha(), done + 1
            commit = self.commit(merged)
            if [p["sha"] for p in commit["parents"]] != [expected, head] or commit["commit"]["tree"]["sha"] != tree:
                self.finished(batch, run, pull, (result or {}).get("merged"),
                              f"merged, but main's tree after it isn't the one run {run['html_url']} tested: main moved "
                              "in the second before the merge. checks.yml runs in full on main to check what landed.")
                why = f"main's tree after #{number} isn't the tested one"
                break
            self.finished(batch, run, pull, (result or {}).get("merged"))
            expected = merged
        return self.end(batch, run, runs, done, why, left)

    def refused(self, pull, error):
        """GitHub refused a member's merge (405: a rule or a check; 409: the head changed): "waits" a poll to try again.
        Only refusals at least a poll apart count; the third sends the member back as on the single path ("left")."""
        number, now = pull["number"], self.slot.now()
        count, last = self.refusals.get(number, (0, None))
        if last is None or now - last >= dt.timedelta(seconds=self.slot.poll):
            count, last = count + 1, now
        self.refusals[number] = (count, last)
        if count < 3:
            self.slot.log(f"#{number}: GitHub refused the merge ({error}); trying again after a poll")
            return "waits"
        self.refusals.pop(number)
        return self.slot.leave(pull, f"GitHub refused the merge three times: {error}")

    def finished(self, batch, run, pull, confirmed, note=None):
        """A member this batch merged: its branches are deleted, then it gets its comment (so a comment means done)."""
        number = pull["number"]
        self.slot.drop_ref(f"{self.prefix}{number}")
        if confirmed and pull["head"]["repo"]["full_name"] == pull["base"]["repo"]["full_name"]:
            self.slot.drop_ref(pull["head"]["ref"])  # GitHub confirmed the merge
        self.slot.label_times.pop(number, None)
        others = ", ".join(f"#{n}" for n, _, _ in batch.members if n != number)
        self.slot.comment(number, note or f"merged after run {run['html_url']} tested it on main `{batch.base[:10]}` in "
                                          f"one batch with {others} (they merge in label order). The branch is deleted; "
                                          "checks.yml runs on main once the batch is in, to refresh the build cache.")
        self.settled.add((batch.sha, number))
        self.slot.log(f"#{number} merged (batch)")

    def settle(self, batch, run, pull):
        """The last member this batch merged before a job stopped may lack its branch deletions and comment: they are
        done again unless its comment is there."""
        if (batch.sha, pull["number"]) in self.settled:
            return
        found = self.gh.call("GET", f"repos/{{repo}}/issues/{pull['number']}/comments?since={run['created_at']}"
                                    "&per_page=100") or []
        if any(run["html_url"] in comment["body"] for comment in found):
            self.settled.add((batch.sha, pull["number"]))
        else:
            self.finished(batch, run, pull, pull.get("merged"))

    def end(self, batch, run, runs, done, why, left):
        """The batch is over. After any merge of it checks.yml runs on main once: not again when a run on main's head
        is listed already (a job dispatched it and stopped before deleting the branch). A batch that stopped part-way,
        the one way main rests on part of a batch, tells each member that didn't merge from it why."""
        if done:
            main = self.slot.main_sha()
            if not any(r["head_branch"] == "main" and r["head_sha"] == main for r in runs):
                self.main_run()
        self.drop(batch, why or "every member merged")
        if done and why:
            landed = ", ".join(f"#{n}" for n, _, _ in batch.members[:done])
            for number, _, _ in batch.members[done:]:
                if number != left:  # one sent back has its own comment
                    self.slot.comment(number, f"its batch stopped after {landed} merged from run {run['html_url']}: "
                                              f"{why}. It didn't merge from that run; with the label on, it is tested "
                                              "again. Main now holds part of the batch, a tree no run tested on its own: "
                                              "checks.yml runs in full on main to check what landed.")
        return "merged" if done else "moved"

    def main_run(self):
        """A merge made with the workflow token starts no push run: checks.yml on main, once per batch."""
        self.gh.call("POST", f"repos/{{repo}}/actions/workflows/{self.workflow}/dispatches", {"ref": "main"})

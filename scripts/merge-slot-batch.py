"""Batches for the merge slot (scripts/merge-slot.py loads this file by path). When more than one labeled pull request
is ready, one checks run tests main plus all of them; if it's green they merge in label order. The rules are in
docs/build/build-and-packaging.md "Merge slot"; checks/MergeSlot/BatchCases.py tests this against a fake GitHub.

A batch lives on the branch merge-slot/pr-batch as one commit made for it:
- its tree is main + the first pull request + the second + ..., merged one after another with the Merges API;
- its parents are main and the members' heads in that order, so checks.yml classifies and measures it against main as
  it does a single pull request's test merge (scripts/ci-docs-only.sh and the preview perf ratchet compare with HEAD^1);
- its message lists each member's number, head and the tree main must have right after merging it.
Everything is read back from GitHub on every pass (the branch, that commit, the runs on the branch), so the workflow's
next job carries on where this one stopped.
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
    """The slot's batch: forms it where the slot would test one pull request, holds the slot while its run goes, merges
    it when green, and after a red one has its members tested one at a time (Slot.serve calls step() every pass)."""

    def __init__(self, slot, error, label, prefix, workflow, workflow_path, max_age, timeout):
        self.slot, self.gh, self.error = slot, slot.gh, error
        self.label, self.prefix, self.workflow, self.workflow_path = label, prefix, workflow, workflow_path
        self.max_age, self.timeout = max_age, timeout
        self.dispatched = {}  # batch commit -> when this job dispatched its run
        self.cancelled = set()  # runs this job asked GitHub to cancel
        self.verdicts = {}  # (run id, attempt) -> the final verdict on a red batch run
        self.commits = {}  # sha -> GET commits/{sha}: a commit never changes

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
        """This pass's batch: "testing" while a batch run holds the slot, "merged" / "moved" when it acted, "fallback"
        while the members of a red batch are tested one at a time, None when there is no batch."""
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
        heads = {pull["number"]: pull["head"]["sha"] for pull in waiting}
        if run is None:
            return self.undispatched(batch, heads)
        if run["status"] != "completed":
            return self.running(batch, run, heads)
        if run["conclusion"] == "success":
            if self.green(run, batch):
                return self.land(batch, run)
            return self.drop(batch, f"its green run {run['html_url']} no longer proves it (a day old?)")
        if self.verdict(run) in ("rerunning", "pending", "green"):
            return "testing"  # GitHub's own failure is being re-run: the slot stays held, as for a single test
        if any(heads.get(number) == head for number, head, _ in batch.members):
            return "fallback"  # each member still at the head it tested is tested alone, oldest first
        return self.drop(batch, f"its run {run['html_url']} ended {run['conclusion']} and each member is done")

    def undispatched(self, batch, heads):
        sent = self.dispatched.get(batch.sha)
        if sent and self.slot.now() - sent < LIST_DELAY:
            return "testing"  # dispatched; GitHub lists the run a little later
        if all(heads.get(n) == h for n, h, _ in batch.members) and self.slot.main_sha() == batch.base:
            return self.dispatch(batch)  # built, never dispatched: the job before this one stopped in between
        return self.drop(batch, "it was never tested, and it changed since")

    def running(self, batch, run, heads):
        number, head, _ = batch.members[0]
        if self.slot.now() - when(run.get("run_started_at") or run["created_at"]) > self.timeout:
            self.cancel(run)  # it ends cancelled; then its members are tested one at a time
            return "testing"
        if heads.get(number) != head:
            why = f"#{number}, the first in it, was pushed, unlabeled or closed"
        elif self.slot.main_sha() != batch.base:
            why = "main moved"
        else:
            return "testing"
        self.cancel(run)  # its result could merge nothing
        self.drop(batch, f"{why} while its run {run['html_url']} went")
        return "testing"  # held until GitHub has stopped the run

    def land(self, batch, run):
        """Merges the green batch in order, each member only while main is exactly the tested chain up to the one
        before it; it stops at the first that changed or the first main move, and the rest go back to waiting."""
        expected, landed, now, why = batch.base, 0, [], "every member merged"
        numbers = [number for number, _, _ in batch.members]
        for at, (number, head, tree) in enumerate(batch.members):
            pull = self.gh.call("GET", f"repos/{{repo}}/pulls/{number}")
            if pull.get("merged"):
                done = pull.get("merge_commit_sha") or ""
                if done and [p["sha"] for p in self.commit(done)["parents"]] == [expected, head] \
                        and self.commit(done)["commit"]["tree"]["sha"] == tree:
                    expected, landed = done, landed + 1  # this batch merged it on an earlier pass
                    continue
                why = f"#{number} was merged some other way"
                break
            if (pull["state"] != "open" or pull["head"]["sha"] != head
                    or not any(l["name"] == self.label for l in pull["labels"])):
                why = f"#{number} was pushed, unlabeled or closed during the run"
                break
            if self.slot.main_sha() != expected:
                why = "main moved through another merge"
                break
            try:
                result = self.gh.call("PUT", f"repos/{{repo}}/pulls/{number}/merge", {"merge_method": "merge", "sha": head})
            except self.error as error:
                if error.status not in (405, 409):
                    raise
                if self.slot.refused(pull, error) != "left":
                    if now:
                        self.main_run()
                    return "moved"  # the batch stays; the next pass tries this member again
                why = f"GitHub refused to merge #{number}"
                break
            merged = (result or {}).get("sha") or self.slot.main_sha()
            self.slot.refusals.pop(number, None)
            self.slot.drop_ref(f"{self.prefix}{number}")
            if (result or {}).get("merged") and pull["head"]["repo"]["full_name"] == pull["base"]["repo"]["full_name"]:
                self.slot.drop_ref(pull["head"]["ref"])
            self.slot.label_times.pop(number, None)
            landed, now = landed + 1, now + [number]
            others, rest = ", ".join(f"#{n}" for n in numbers if n != number), numbers[at + 1:]
            if [p["sha"] for p in self.commit(merged)["parents"]] != [expected, head] \
                    or self.commit(merged)["commit"]["tree"]["sha"] != tree:
                self.slot.comment(number, f"merged, but main's tree after it isn't the one run {run['html_url']} "
                                          "tested: main moved in the second before the merge. "
                                          + (f"The rest of its batch ({', '.join(f'#{n}' for n in rest)}) goes back to "
                                             "waiting; " if rest else "")
                                          + "checks.yml on main checks what landed.")
                why = f"main's tree after #{number} isn't the tested one"
                break
            self.slot.comment(number, f"merged after run {run['html_url']} tested it on main `{batch.base[:10]}` in one "
                                      f"batch with {others} (they merge in label order). The branch is deleted; "
                                      "checks.yml runs on main once the batch is in, to refresh the build cache.")
            self.slot.log(f"#{number} merged (batch)")
            expected = merged
        if landed:
            self.main_run()
        self.drop(batch, why)
        return "merged" if now else "moved"

    def main_run(self):
        """A merge made with the workflow token starts no push run: checks.yml on main, once per batch."""
        self.gh.call("POST", f"repos/{{repo}}/actions/workflows/{self.workflow}/dispatches", {"ref": "main"})

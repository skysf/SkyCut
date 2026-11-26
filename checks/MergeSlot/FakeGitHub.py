"""An in-memory GitHub for checks/MergeSlot/: just the calls scripts/merge-slot.py and scripts/ci-infra-rerun.py make.

Pull requests, refs, commits, check runs, workflow runs with their jobs (FakeJobs.py) and markers live in
dictionaries. A dispatch on merge-slot/pr-<N> (or the batch's merge-slot/pr-batch) queues a checks run for that ref's
head, and a re-run queues the run's next attempt; tick() (the slot's sleep) moves time on and finishes queued runs with
the outcome a scenario set (or red when the tested commit contains a breaking head), leaving a marker for green ones
like checks.yml's summary job does. A cancelled run ends two ticks later, as GitHub stops one a little later.
"""
import datetime as dt
import itertools
import re
import urllib.parse

from FakeJobs import Jobs, conclusion_of

REPO = "o/r"
START = dt.datetime(2026, 11, 20, 8, 0, tzinfo=dt.timezone.utc)
OUTCOMES = {"success": "success", "failure": "failure", "cancelled": "cancelled"}  # a run's conclusion -> its jobs


class HTTPError(Exception):
    pass


def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeGitHub:
    def __init__(self, error_type):
        self.error_type = error_type  # the slot's GitHubError(status, message)
        self.clock = START
        self.ids = itertools.count(100)
        self.commits = {}
        self.main = self.commit([], "tree-main-0")
        self.pulls, self.checks, self.runs, self.markers = {}, {}, {}, {}
        self.label_events, self.comments, self.refs = {}, {}, {}
        self.dispatches, self.merged, self.deleted, self.overlaps = [], [], [], []
        self.merged_heads = {}  # number -> the head that merged
        self.outcomes = {}  # ref -> conclusion its next dispatched runs get
        self.refuse_merge = 0  # how many merges GitHub refuses with 405 before accepting
        self.race = False  # someone merges by hand right before the slot merges
        self.head_race = False  # a new head is pushed right before the slot merges
        self.frozen = 0  # ticks during which GitHub doesn't recompute test merge commits
        self.merges_made = 0  # POST /merges calls that made a commit
        self.lost_markers = set()  # refs whose green runs fail to upload their marker (the upload is continue-on-error)
        self.on_tick = None  # a scenario hook: called with this fake on every tick
        self.calls = []
        self.make = Jobs()
        self.jobs, self.notes = {}, {}  # run id -> {attempt: [job]}; job id -> its annotation messages
        self.plans, self.trees = {}, {}  # run id -> outcome per attempt (the last repeats); run id -> marker tree
        self.reruns = []  # run ids whose failed jobs were re-run (POST rerun-failed-jobs)
        self.refuse_rerun = False  # GitHub refuses re-runs (403) even of completed runs
        self.slow_tests = 0  # polls a dispatched slot test stays in progress before it ends
        self.list_delay = 0  # polls before GitHub lists a dispatched run (it does so a little later)
        self.breaking = set()  # heads whose code fails every run of a commit that contains them
        self.cancel_delay = 2  # ticks before a cancelled run has stopped
        self.cancels, self.redispatched, self.created = [], [], []  # runs cancelled; dispatches on a busy ref; new refs
        self.after_merge = None  # a scenario hook: called with this fake and the number after each pull request merges
        self.race_on_merge = None  # this pull request's merge finds main moved by a hand merge a second before
        self.push_before_merge = None  # this pull request gets a new head in the second before the slot merges it
        self.fail_dispatch = set()  # refs whose next dispatch fails (HTTP 500), like a job dying right there
        self.fail_delete = set()  # refs whose next deletion fails (HTTP 500), like a job dying right there
        self.refused_at = []  # (number, clock) of each merge GitHub refused
        self.main_after = []  # at each dispatch on main: how many pull requests had merged by then

    # ---- building the world ----
    def commit(self, parents, tree, message=""):
        sha = f"{next(self.ids):040x}"
        self.commits[sha] = {"parents": parents, "tree": tree, "message": message}
        return sha

    def contains(self, sha, target):
        """target is sha or one of its ancestors."""
        seen, todo = set(), [sha]
        while todo:
            current = todo.pop()
            if current == target:
                return True
            if current not in seen:
                seen.add(current)
                todo += self.commits[current]["parents"]
        return False

    def open_pull(self, number, check="success", labeled_minutes=0, fork=False, draft=False, mergeable=True,
                  workflow=False):
        head = self.commit([self.main], f"tree-head-{number}")
        self.pulls[number] = {
            "number": number, "state": "open", "draft": draft, "merged": False,
            "labels": [{"name": "merge-slot"}], "created_at": stamp(START),
            "head": {"sha": head, "ref": f"topic-{number}", "repo": {"full_name": "fork/r" if fork else REPO}},
            "base": {"ref": "main", "repo": {"full_name": REPO}},
            "mergeable": mergeable, "merge_commit_sha": None,
            "files": [".github/workflows/checks.yml"] if workflow else [f"docs/change-{number}.md"],
        }
        self.label_events[number] = [stamp(START + dt.timedelta(minutes=labeled_minutes))]
        self.set_check(head, check)
        self.refresh(number)
        return head

    def refresh(self, number):
        """GitHub recomputing the test merge commit of a pull request for the current main and head."""
        pull = self.pulls[number]
        if pull["mergeable"] is not False:
            pull["merge_commit_sha"] = self.commit([self.main, pull["head"]["sha"]],
                                                   self.merged_tree(self.main, pull["head"]["sha"]))

    def set_check(self, sha, conclusion, run_id=None):
        """check-all on a commit; with run_id its details URL names that run, as GitHub's does."""
        status = "in_progress" if conclusion is None else "completed"
        check_id = next(self.ids)
        url = f"https://example.invalid/{REPO}/actions/runs/{run_id}/job/{check_id}" if run_id else "https://example.invalid/job"
        self.checks[sha] = [{"id": check_id, "status": status, "conclusion": conclusion,
                             "started_at": stamp(self.clock), "details_url": url}]

    def add_run(self, event, head_sha, head_branch, conclusion, tree=None, marker=True, created=None, forced=False,
                jobs=None):
        """A checks run; jobs: its first attempt's jobs (else made to fit the conclusion)."""
        run_id = next(self.ids)
        if jobs is not None:
            conclusion = conclusion_of(jobs)
        self.runs[run_id] = {
            "id": run_id, "path": ".github/workflows/checks.yml", "event": event, "head_sha": head_sha,
            "head_branch": head_branch, "status": "completed" if conclusion else "queued",
            "conclusion": conclusion, "created_at": stamp(created or self.clock), "run_attempt": 1,
            "updated_at": stamp(created or self.clock),
            "run_started_at": stamp(created or self.clock),
            "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO},
            "html_url": f"https://example.invalid/runs/{run_id}",
        }
        if conclusion:
            self.set_jobs(run_id, 1, jobs if jobs is not None else self.make.run(OUTCOMES[conclusion]))
        if tree:
            self.trees[run_id] = tree
        if tree and ((conclusion == "success" and marker) or forced):  # forced: a marker a green run never left
            self.markers.setdefault(f"verified-tree-{tree}", []).append(run_id)
        return run_id

    def set_jobs(self, run_id, attempt, jobs):
        self.jobs.setdefault(run_id, {})[attempt] = [job for job, _ in jobs]
        for job, messages in jobs:
            self.notes[job["id"]] = messages

    def pr_run(self, number, conclusion="success", plan=None, jobs=None):
        """The pull request's own run on its current test merge commit (its marker names that tree). plan: outcomes
        per attempt (FakeJobs.Jobs.run keywords, the last repeats); then check-all on the head is this run's."""
        pull = self.pulls[number]
        tree = self.commits[pull["merge_commit_sha"]]["tree"]
        run_id = self.add_run("pull_request", pull["head"]["sha"], pull["head"]["ref"], conclusion, tree,
                              jobs=jobs if jobs is not None else (self.make.run(plan[0]) if plan else None))
        if plan or jobs is not None:
            self.plans[run_id] = plan or ["success"]
            self.set_check(pull["head"]["sha"], self.runs[run_id]["conclusion"], run_id)
        return run_id

    def planned(self, run):
        """The outcome of the run's current attempt: its plan, else its ref's outcome; re-runs default to green."""
        if any(self.contains(run["head_sha"], head) for head in self.breaking):
            return "failure"  # broken code fails every attempt
        plan = self.plans.get(run["id"]) or self.outcomes.get(run["head_branch"], "success")
        plan = [plan, "success"] if isinstance(plan, str) else plan
        return plan[min(run["run_attempt"], len(plan)) - 1]

    def finish(self, run, outcome):
        """A queued attempt ends like `outcome`; a green one leaves its marker; a pull request's sets check-all."""
        jobs = self.make.run(outcome)
        self.set_jobs(run["id"], run["run_attempt"], jobs)
        run["status"], run["conclusion"] = "completed", conclusion_of(jobs)
        run["updated_at"] = stamp(self.clock)
        if run["conclusion"] == "success" and run["head_branch"] not in self.lost_markers:
            tree = self.trees.get(run["id"]) or self.commits[run["head_sha"]]["tree"]
            self.markers.setdefault(f"verified-tree-{tree}", []).append(run["id"])
        if run["event"] == "pull_request":
            self.set_check(run["head_sha"], run["conclusion"], run["id"])

    def rerun_green(self, run_id):
        """An author re-runs a red run's failed jobs and they pass: the same run turns green and leaves its marker."""
        run = self.runs[run_id]
        run["run_attempt"] += 1
        self.finish(run, "success")

    def relabel(self, number):
        self.pulls[number]["labels"] = [{"name": "merge-slot"}]
        self.label_events[number].append(stamp(self.clock))

    def human_merge(self, tree="tree-elsewhere", refresh=True):
        """Someone moves main outside the slot; GitHub recomputes every open pull request (or, refresh=False, later)."""
        self.main = self.commit([self.main], tree)
        for number in self.pulls if refresh else ():
            if self.pulls[number]["state"] == "open":
                self.refresh(number)

    # ---- the slot's view ----
    def tick(self, seconds):
        self.clock += dt.timedelta(seconds=seconds)
        self.frozen = max(0, self.frozen - 1)
        for run in list(self.runs.values()):
            run["unlisted"] = max(0, run.get("unlisted", 0) - 1)
            if run["status"] != "completed" and run.get("cancel_requested"):
                run["cancel_ticks"] -= 1
                if run["cancel_ticks"] <= 0:
                    self.finish(run, "cancelled")  # GitHub stops a cancelled run a little later
                continue
            if run["status"] != "completed" and (run["run_attempt"] > 1 or (
                    run["event"] == "workflow_dispatch" and run["head_branch"] != "main")):
                if run.get("ticks_left", 0) > 0:  # a slow slot test: still running
                    run["ticks_left"] -= 1
                    run["status"] = "in_progress"
                    continue
                self.finish(run, self.planned(run))
        if self.on_tick:
            self.on_tick(self)

    def error(self, status, message):
        return self.error_type(status, message)

    def call(self, method, path, body=None):
        path = path.replace("{repo}", REPO)
        self.calls.append((method, path))
        route = path.split("?")[0]
        query = {k: urllib.parse.unquote(v) for k, v in re.findall(r"[?&]([^=&]+)=([^&]*)", path)}
        prefix = f"repos/{REPO}/"
        assert route.startswith(prefix), path
        route = route[len(prefix):]
        if method == "GET" and route == "pulls":
            return [p for p in self.pulls.values() if p["state"] == "open"]
        if m := re.fullmatch(r"pulls/(\d+)/files", route):
            page = int(query.get("page", "1"))
            files = self.pulls[int(m.group(1))]["files"]
            return [{"filename": f} for f in files[(page - 1) * 100:page * 100]]
        if m := re.fullmatch(r"pulls/(\d+)", route):
            # Like GitHub: the test merge (merge_commit_sha) is recomputed for new commits, not when main moves.
            return self.pulls[int(m.group(1))]
        if m := re.fullmatch(r"issues/(\d+)/events", route):
            return [{"event": "labeled", "label": {"name": "merge-slot"}, "created_at": t}
                    for t in self.label_events[int(m.group(1))]]
        if m := re.fullmatch(r"git/ref/heads/(.+)", route):
            ref = m.group(1)
            if ref == "main":
                return {"object": {"sha": self.main}}
            heads = [p["head"]["sha"] for p in self.pulls.values() if p["head"]["ref"] == ref and p["state"] == "open"]
            if heads:  # a pull request's branch
                return {"object": {"sha": heads[0]}}
            if ref not in self.refs:
                raise self.error(404, "Not Found")
            return {"object": {"sha": self.refs[ref]}}
        if route == "merges" and method == "POST":
            return self.merge_api(body)
        if m := re.fullmatch(r"commits/([0-9a-f]+)/check-runs", route):
            assert query.get("check_name") == "check-all", path
            return {"check_runs": self.checks.get(m.group(1), [])}
        if m := re.fullmatch(r"commits/([0-9a-f]+)", route):
            c = self.commits[m.group(1)]
            return {"sha": m.group(1), "parents": [{"sha": p} for p in c["parents"]],
                    "commit": {"tree": {"sha": c["tree"]}, "message": c["message"]}}
        if route == "git/commits" and method == "POST":
            assert all(p in self.commits for p in body["parents"]), body
            assert any(c["tree"] == body["tree"] for c in self.commits.values()), body  # only a tree GitHub made
            sha = self.commit(list(body["parents"]), body["tree"], body["message"])
            return {"sha": sha, "tree": {"sha": body["tree"]}, "parents": [{"sha": p} for p in body["parents"]]}
        if route == "actions/artifacts":
            # The marker lookup is the slot's last read before it merges: the races strike here.
            if self.race:
                self.race = False
                self.main = self.commit([self.main], "tree-raced")  # someone merges by hand
            if self.head_race:
                self.head_race = False
                for pull in self.pulls.values():
                    if pull["state"] == "open":
                        pull["head"]["sha"] = self.commit([self.main], f"tree-raced-head-{pull['number']}")
                        self.set_check(pull["head"]["sha"], "success")
            ids = self.markers.get(query["name"], [])
            return {"artifacts": [{"expired": False, "workflow_run": {"id": i, "repository_id": 1, "head_repository_id": 1}}
                                  for i in ids]}
        if m := re.fullmatch(r"actions/runs/(\d+)", route):
            return self.runs[int(m.group(1))]
        if m := re.fullmatch(r"actions/runs/(\d+)/attempts/(\d+)/jobs", route):
            return {"jobs": self.jobs[int(m.group(1))][int(m.group(2))]}
        if m := re.fullmatch(r"check-runs/(\d+)/annotations", route):
            return [{"annotation_level": "failure", "message": text} for text in self.notes.get(int(m.group(1)), [])]
        if (m := re.fullmatch(r"actions/runs/(\d+)/cancel", route)) and method == "POST":
            run = self.runs[int(m.group(1))]
            if run["status"] == "completed":
                raise self.error(409, "Cannot cancel a workflow run that is completed.")
            run["cancel_requested"], run["cancel_ticks"] = True, self.cancel_delay
            self.cancels.append(run["id"])
            return None
        if (m := re.fullmatch(r"actions/runs/(\d+)/rerun-failed-jobs", route)) and method == "POST":
            run = self.runs[int(m.group(1))]
            if run["status"] != "completed" or self.refuse_rerun:
                raise self.error(403, "This workflow is already running")
            run.update(run_attempt=run["run_attempt"] + 1, status="queued", conclusion=None,
                       run_started_at=stamp(self.clock), updated_at=stamp(self.clock))
            self.reruns.append(run["id"])
            return None
        if route == "actions/workflows/checks.yml/runs":  # newest first, like GitHub
            found = [r for r in self.runs.values() if query.get("branch") in (None, r["head_branch"])
                     and query.get("event") in (None, r["event"]) and not r.get("unlisted")]
            found.sort(key=lambda r: -r["id"])
            return {"workflow_runs": found[:int(query.get("per_page", "30"))]}
        if route == "actions/workflows/checks.yml/dispatches" and method == "POST":
            ref = body["ref"]
            if ref in self.fail_dispatch:
                self.fail_dispatch.discard(ref)
                raise self.error(500, "Server Error")
            busy = [r["head_branch"] for r in self.runs.values() if r["status"] != "completed"
                    and r["head_branch"].startswith("merge-slot/") and r["head_branch"] != ref]
            if busy and ref != "main":
                self.overlaps.append((ref, busy))
            if any(r["status"] != "completed" and r["head_branch"] == ref for r in self.runs.values()):
                self.redispatched.append(ref)  # GitHub would cancel the older run (same concurrency group)
            self.dispatches.append(ref)
            if ref == "main":
                self.main_after.append(len(self.merged))
            head = self.main if ref == "main" else self.refs[ref]
            run_id = self.add_run("workflow_dispatch", head, ref, None)
            self.runs[run_id]["ticks_left"] = self.slow_tests if ref != "main" else 0
            self.runs[run_id]["unlisted"] = self.list_delay
            if ref == "main":
                self.runs[run_id]["status"] = "completed"
            return None
        if route.startswith("git/matching-refs/heads/"):
            prefix = route[len("git/matching-refs/heads/"):]
            return [{"ref": f"refs/heads/{name}"} for name in self.refs if name.startswith(prefix)]
        if m := re.fullmatch(r"git/refs/heads/(.+)", route):
            ref = m.group(1)
            if method == "PATCH":
                if ref not in self.refs:
                    raise self.error(422, "Reference does not exist")
                self.refs[ref] = body["sha"]
                return {}
            if method == "DELETE":
                if ref in self.fail_delete:
                    self.fail_delete.discard(ref)
                    raise self.error(500, "Server Error")
                if ref not in self.refs and not ref.startswith("topic-"):
                    raise self.error(422, "Reference does not exist")
                self.refs.pop(ref, None)
                self.deleted.append(ref)
                return None
        if route == "git/refs" and method == "POST":
            self.refs[body["ref"][len("refs/heads/"):]] = body["sha"]
            self.created.append(body["ref"][len("refs/heads/"):])
            return {}
        if m := re.fullmatch(r"pulls/(\d+)/merge", route):
            return self.merge(int(m.group(1)), body)
        if m := re.fullmatch(r"issues/(\d+)/comments", route):
            if method == "GET":  # oldest first, like GitHub (since: every comment here is recent enough)
                return [{"body": text} for text in self.comments.get(int(m.group(1)), [])]
            self.comments.setdefault(int(m.group(1)), []).append(body["body"])
            return {}
        if m := re.fullmatch(r"issues/(\d+)/labels/merge-slot", route):
            pull = self.pulls[int(m.group(1))]
            pull["labels"] = [l for l in pull["labels"] if l["name"] != "merge-slot"]
            return None
        raise AssertionError(f"the fake doesn't know {method} {path}")

    def merged_tree(self, base, head):
        """A merge's tree is named by both sides' trees, so a different main or head is a different tree."""
        return self.merged_tree_of(self.commits[base]["tree"], head)

    def merged_tree_of(self, tree, head):
        return f"({tree}+{self.commits[head]['tree']})"

    def number_of(self, head):
        return next(n for n, p in self.pulls.items() if p["head"]["sha"] == head)

    def merge_api(self, body):
        """POST /merges: merge a head into a branch (here merge-slot/pr-<N>), as GitHub's PR merge would."""
        base = self.refs[body["base"]]
        number = self.number_of(body["head"])
        if self.pulls[number]["mergeable"] is False or self.clashes(number, base):
            raise self.error(409, "Merge conflict")
        if any(f.startswith(".github/workflows/") for f in self.pulls[number]["files"]):
            # Like GitHub: the workflow token may not create or update workflow files (2026-11-19, #527).
            raise self.error(409, "refusing to allow a GitHub App to create or update workflow without workflows permission")
        if self.contains(base, body["head"]):
            return None  # 204: nothing to merge
        self.merges_made += 1
        sha = self.commit([base, body["head"]], self.merged_tree(base, body["head"]), body.get("commit_message", ""))
        self.refs[body["base"]] = sha
        return {"sha": sha, "commit": {"tree": {"sha": self.commits[sha]["tree"]}},
                "parents": [{"sha": base}, {"sha": body["head"]}]}

    def clashes(self, number, base):
        """The pull request conflicts with one that base already contains (conflicts_with: their numbers)."""
        return any(self.contains(base, self.pulls[other]["head"]["sha"])
                   for other in self.pulls[number].get("conflicts_with", ()))

    def merge(self, number, body):
        pull = self.pulls[number]
        assert body["merge_method"] == "merge", body
        if self.push_before_merge == number:
            self.push_before_merge = None
            pull["head"]["sha"] = self.commit([self.main], f"tree-pushed-{number}")
            self.set_check(pull["head"]["sha"], "success")
        if body.get("sha", pull["head"]["sha"]) != pull["head"]["sha"]:  # without sha, GitHub merges the head it has
            self.refused_at.append((number, self.clock))
            raise self.error(409, "Head branch was modified")
        if any(f.startswith(".github/workflows/") for f in pull["files"]):
            raise self.error(403, "Resource not accessible by integration")
        if self.refuse_merge:
            self.refuse_merge -= 1
            self.refused_at.append((number, self.clock))
            raise self.error(405, "Required status check check-all is failing")
        if self.checks[pull["head"]["sha"]][-1]["conclusion"] != "success":
            raise self.error(405, "Required status check check-all is failing")
        if self.clashes(number, self.main):
            raise self.error(405, "Pull Request is not mergeable")
        if self.race_on_merge == number:
            self.race_on_merge = None
            self.main = self.commit([self.main], "tree-raced")  # someone merged by hand a second before
        # What lands is main as it is now + the head as it is now, whatever any test merge said.
        landed = self.merged_tree(self.main, pull["head"]["sha"])
        made = self.main = self.commit([self.main, pull["head"]["sha"]], landed)
        pull.update(state="closed", merged=True, merge_commit_sha=made)
        self.merged.append((number, landed))
        self.merged_heads[number] = pull["head"]["sha"]
        for other in self.pulls:
            if self.pulls[other]["state"] == "open":
                self.refresh(other)
        if self.after_merge:
            self.after_merge(self, number)  # may move main again: the answer still names this merge's commit
        return {"sha": made, "merged": True, "message": "Pull Request successfully merged"}

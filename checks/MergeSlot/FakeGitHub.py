"""An in-memory GitHub for checks/MergeSlot/MergeSlotChecks.py: just the calls scripts/merge-slot.py makes.

Pull requests, refs, commits, check runs, workflow runs and markers live in dictionaries. A dispatch on
merge-slot/pr-<N> queues a checks run for that ref's head; tick() (the slot's sleep) moves time on and finishes queued
runs with the outcome a scenario set, leaving a marker for green ones like checks.yml's summary job does.
"""
import datetime as dt
import itertools
import re

REPO = "o/r"
START = dt.datetime(2026, 11, 20, 8, 0, tzinfo=dt.timezone.utc)


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
        self.outcomes = {}  # ref -> conclusion its next dispatched runs get
        self.refuse_merge = 0  # how many merges GitHub refuses with 405 before accepting
        self.race = False  # someone merges by hand right before the slot merges
        self.head_race = False  # a new head is pushed right before the slot merges
        self.frozen = 0  # ticks during which GitHub doesn't recompute test merge commits
        self.merges_made = 0  # POST /merges calls that made a commit
        self.lost_markers = set()  # refs whose green runs fail to upload their marker (the upload is continue-on-error)
        self.on_tick = None  # a scenario hook: called with this fake on every tick
        self.calls = []

    # ---- building the world ----
    def commit(self, parents, tree):
        sha = f"{next(self.ids):040x}"
        self.commits[sha] = {"parents": parents, "tree": tree}
        return sha

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

    def set_check(self, sha, conclusion):
        status = "in_progress" if conclusion is None else "completed"
        self.checks[sha] = [{"id": next(self.ids), "status": status, "conclusion": conclusion,
                             "started_at": stamp(self.clock), "details_url": "https://example.invalid/job"}]

    def add_run(self, event, head_sha, head_branch, conclusion, tree=None, marker=True, created=None, forced=False):
        run_id = next(self.ids)
        self.runs[run_id] = {
            "id": run_id, "path": ".github/workflows/checks.yml", "event": event, "head_sha": head_sha,
            "head_branch": head_branch, "status": "completed" if conclusion else "queued",
            "conclusion": conclusion, "created_at": stamp(created or self.clock),
            "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO},
            "html_url": f"https://example.invalid/runs/{run_id}",
        }
        if tree and ((conclusion == "success" and marker) or forced):  # forced: a marker a green run never left
            self.markers.setdefault(f"verified-tree-{tree}", []).append(run_id)
        return run_id

    def pr_run(self, number, conclusion="success"):
        """The pull request's own run on its current test merge commit (its marker names that tree)."""
        pull = self.pulls[number]
        tree = self.commits[pull["merge_commit_sha"]]["tree"]
        return self.add_run("pull_request", pull["head"]["sha"], pull["head"]["ref"], conclusion, tree)

    def rerun_green(self, run_id):
        """An author re-runs a red run's failed jobs and they pass: the same run turns green and leaves its marker."""
        run = self.runs[run_id]
        run.update(status="completed", conclusion="success")
        self.markers.setdefault(f"verified-tree-{self.commits[run['head_sha']]['tree']}", []).append(run_id)

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
            if run["status"] != "completed" and run["event"] == "workflow_dispatch" and run["head_branch"] != "main":
                run["status"], run["conclusion"] = "completed", self.outcomes.get(run["head_branch"], "success")
                if run["conclusion"] == "success" and run["head_branch"] not in self.lost_markers:
                    tree = self.commits[run["head_sha"]]["tree"]
                    self.markers.setdefault(f"verified-tree-{tree}", []).append(run["id"])
        if self.on_tick:
            self.on_tick(self)

    def error(self, status, message):
        return self.error_type(status, message)

    def call(self, method, path, body=None):
        path = path.replace("{repo}", REPO)
        self.calls.append((method, path))
        route = path.split("?")[0]
        query = dict(re.findall(r"[?&]([^=&]+)=([^&]*)", path))
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
            return {"sha": m.group(1), "parents": [{"sha": p} for p in c["parents"]], "commit": {"tree": {"sha": c["tree"]}}}
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
        if route == "actions/workflows/checks.yml/runs":
            found = [r for r in self.runs.values() if r["event"] == query.get("event") and r["head_branch"] == query.get("branch")]
            return {"workflow_runs": found}
        if route == "actions/workflows/checks.yml/dispatches" and method == "POST":
            ref = body["ref"]
            busy = [r["head_branch"] for r in self.runs.values() if r["status"] != "completed"
                    and r["head_branch"].startswith("merge-slot/") and r["head_branch"] != ref]
            if busy and ref != "main":
                self.overlaps.append((ref, busy))
            self.dispatches.append(ref)
            head = self.main if ref == "main" else self.refs[ref]
            run_id = self.add_run("workflow_dispatch", head, ref, None)
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
                if ref not in self.refs and not ref.startswith("topic-"):
                    raise self.error(422, "Reference does not exist")
                self.refs.pop(ref, None)
                self.deleted.append(ref)
                return None
        if route == "git/refs" and method == "POST":
            self.refs[body["ref"][len("refs/heads/"):]] = body["sha"]
            return {}
        if m := re.fullmatch(r"pulls/(\d+)/merge", route):
            return self.merge(int(m.group(1)), body)
        if m := re.fullmatch(r"issues/(\d+)/comments", route):
            self.comments.setdefault(int(m.group(1)), []).append(body["body"])
            return {}
        if m := re.fullmatch(r"issues/(\d+)/labels/merge-slot", route):
            pull = self.pulls[int(m.group(1))]
            pull["labels"] = [l for l in pull["labels"] if l["name"] != "merge-slot"]
            return None
        raise AssertionError(f"the fake doesn't know {method} {path}")

    def merged_tree(self, base, head):
        """A merge's tree is named by both sides' trees, so a different main or head is a different tree."""
        return f"({self.commits[base]['tree']}+{self.commits[head]['tree']})"

    def number_of(self, head):
        return next(n for n, p in self.pulls.items() if p["head"]["sha"] == head)

    def merge_api(self, body):
        """POST /merges: merge a head into a branch (here merge-slot/pr-<N>), as GitHub's PR merge would."""
        base = self.refs[body["base"]]
        number = self.number_of(body["head"])
        if self.pulls[number]["mergeable"] is False:
            raise self.error(409, "Merge conflict")
        if any(f.startswith(".github/workflows/") for f in self.pulls[number]["files"]):
            # Like GitHub: the workflow token may not create or update workflow files (2026-11-19, #527).
            raise self.error(409, "refusing to allow a GitHub App to create or update workflow without workflows permission")
        self.merges_made += 1
        sha = self.commit([base, body["head"]], self.merged_tree(base, body["head"]))
        self.refs[body["base"]] = sha
        return {"sha": sha, "commit": {"tree": {"sha": self.commits[sha]["tree"]}},
                "parents": [{"sha": base}, {"sha": body["head"]}]}

    def merge(self, number, body):
        pull = self.pulls[number]
        assert body["merge_method"] == "merge", body
        if body.get("sha", pull["head"]["sha"]) != pull["head"]["sha"]:  # without sha, GitHub merges the head it has
            raise self.error(409, "Head branch was modified")
        if any(f.startswith(".github/workflows/") for f in pull["files"]):
            raise self.error(403, "Resource not accessible by integration")
        if self.refuse_merge:
            self.refuse_merge -= 1
            raise self.error(405, "Required status check check-all is failing")
        if self.checks[pull["head"]["sha"]][-1]["conclusion"] != "success":
            raise self.error(405, "Required status check check-all is failing")
        # What lands is main as it is now + the head as it is now, whatever any test merge said.
        landed = self.merged_tree(self.main, pull["head"]["sha"])
        self.main = self.commit([self.main, pull["head"]["sha"]], landed)
        pull.update(state="closed", merged=True)
        self.merged.append((number, landed))
        for other in self.pulls:
            if self.pulls[other]["state"] == "open":
                self.refresh(other)
        return {"merged": True}

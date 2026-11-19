#!/usr/bin/env python3
"""The merge slot: merges pull requests labeled merge-slot one at a time, each only after a green checks run on the
exact tree that lands (main + the pull request). .github/workflows/merge-slot.yml runs it; the rules are in
docs/build/build-and-packaging.md "Merge slot" and AGENTS.md 「合并与分支」. checks/MergeSlot/MergeSlotChecks.py tests
it against a fake GitHub.

A labeled pull request, oldest label first:
1. waits until check-all on its head is green (red leaves the slot with a comment);
2. builds the test merge X of the head into the current main on the branch merge-slot/pr-<N> with the Merges API
   (parents: main, head), once per main and head; a conflict leaves the slot with a comment. GitHub's own test merge
   (merge_commit_sha) isn't used: GitHub recomputes it when the pull request gets new commits, not when main moves
   (2026-11-19: #527 waited 20 minutes on one built on the old main);
3. merges at once if a green checks run already tested X's tree: the marker verified-tree-<tree> of its own
   pull_request run (main hasn't moved since) or of an earlier slot run;
4. else dispatches checks.yml on merge-slot/pr-<N>, which runs the same workflow file on the same tree as a
   pull_request run on main + head; red or cancelled leaves the slot with a comment. While that run is going,
   nothing else merges;
5. merges (--merge, head pinned) only while main is still X's first parent, then dispatches checks.yml on main (a
   merge made with the workflow token starts no push run) and deletes the pull request's branch and merge-slot/pr-<N>.
A pull request that changes .github/workflows/ leaves at once with the by-hand path: GitHub doesn't let the workflow
token create or update workflow files, so the slot can neither build its test merge nor merge it (2026-11-19, #527).
"""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys
import time

LABEL = "merge-slot"
WORKFLOW = "checks.yml"
WORKFLOW_PATH = ".github/workflows/checks.yml"
SLOT_PREFIX = "merge-slot/pr-"
MARKER_MAX_AGE = dt.timedelta(hours=24)  # same limit as scripts/ci-verified-tree.sh
TEST_TIMEOUT = dt.timedelta(hours=3)


class GitHubError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


class GitHub:
    """`gh api` with JSON in and out."""

    def __init__(self, repo):
        self.repo = repo

    def call(self, method, path, body=None):
        args = ["gh", "api", "-X", method, path.replace("{repo}", self.repo)]
        if body is not None:
            args += ["--input", "-"]
        done = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                              capture_output=True, text=True)
        if done.returncode != 0:  # gh says "gh: Not Found (HTTP 404)" on stderr
            found = re.search(r"\(HTTP (\d{3})\)", done.stderr)
            raise GitHubError(int(found.group(1)) if found else 0, (done.stderr or done.stdout).strip()[:300])
        return json.loads(done.stdout) if done.stdout.strip() else None


def when(text):
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


class Slot:
    def __init__(self, gh, now=lambda: dt.datetime.now(dt.timezone.utc), sleep=time.sleep, log=print):
        self.gh, self.now, self.sleep, self.log = gh, now, sleep, log
        self.label_times = {}
        self.dispatched = {}  # (number, merge commit) -> when this job dispatched its test
        self.refusals = {}  # number -> merges GitHub refused in a row
        self.left = {}  # number -> (head, label time) when it left: skipped until either changes
        self.workflows = {}  # (number, head) -> the .github/workflows/ files it changes

    # ---- reading GitHub ----
    def queue(self):
        """Open pull requests carrying the label, oldest label first."""
        pulls = self.gh.call("GET", "repos/{repo}/pulls?state=open&per_page=100")
        queued = [p for p in pulls if any(label["name"] == LABEL for label in p["labels"])]
        for pull in queued:
            if pull["number"] not in self.label_times:
                events = self.gh.call("GET", f"repos/{{repo}}/issues/{pull['number']}/events?per_page=100")
                times = [e["created_at"] for e in events if e["event"] == "labeled" and e["label"]["name"] == LABEL]
                self.label_times[pull["number"]] = max(times) if times else pull["created_at"]
        return sorted(queued, key=lambda p: (self.label_times[p["number"]], p["number"]))

    def main_sha(self):
        return self.gh.call("GET", "repos/{repo}/git/ref/heads/main")["object"]["sha"]

    def head_check(self, sha):
        """The newest check-all on the head: (status, conclusion, details URL), or None."""
        runs = self.gh.call("GET", f"repos/{{repo}}/commits/{sha}/check-runs?check_name=check-all&filter=latest")
        runs = sorted(runs["check_runs"], key=lambda r: (r.get("started_at") or "", r["id"]))
        return (runs[-1]["status"], runs[-1]["conclusion"], runs[-1].get("details_url", "")) if runs else None

    def workflow_files(self, number, head):
        """The .github/workflows/ files the pull request changes (read once per head)."""
        if (number, head) not in self.workflows:
            found, page = [], 1
            while True:
                files = self.gh.call("GET", f"repos/{{repo}}/pulls/{number}/files?per_page=100&page={page}") or []
                found += [name for f in files for name in (f["filename"], f.get("previous_filename") or "")
                          if name.startswith(".github/workflows/")]
                if len(files) < 100:
                    break
                page += 1
            self.workflows[(number, head)] = sorted(set(found))
        return self.workflows[(number, head)]

    def run_is_green(self, run_id, head, base):
        """A completed green checks.yml run of this repository that tested base + head, under a day old."""
        run = self.gh.call("GET", f"repos/{{repo}}/actions/runs/{run_id}")
        own = run["repository"]["full_name"]
        if (run["path"] != WORKFLOW_PATH or run["status"] != "completed" or run["conclusion"] != "success"
                or (run.get("head_repository") or {}).get("full_name") != own
                or self.now() - when(run["created_at"]) >= MARKER_MAX_AGE):
            return False
        if run["event"] == "pull_request":
            return run["head_sha"] == head
        if run["event"] == "workflow_dispatch" and run["head_branch"].startswith(SLOT_PREFIX):
            parents = [p["sha"] for p in self.gh.call("GET", f"repos/{{repo}}/commits/{run['head_sha']}")["parents"]]
            return parents == [base, head]
        return False

    def verified(self, tree, head, base):
        """The run whose marker proves this tree green for this head and base, or None."""
        found = self.gh.call("GET", f"repos/{{repo}}/actions/artifacts?name=verified-tree-{tree}&per_page=100")
        for artifact in found["artifacts"]:
            run = artifact.get("workflow_run") or {}
            if artifact["expired"] or not run or run["repository_id"] != run["head_repository_id"]:
                continue
            if self.run_is_green(run["id"], head, base):
                return run["id"]
        return None

    def slot_run(self, number, merge_sha):
        """The newest slot test run of this merge commit, or None."""
        runs = self.gh.call("GET", f"repos/{{repo}}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch"
                                   f"&branch={SLOT_PREFIX}{number}&per_page=20")["workflow_runs"]
        runs = [r for r in runs if r["head_sha"] == merge_sha]
        return max(runs, key=lambda r: r["id"]) if runs else None

    # ---- acting ----
    def comment(self, number, text):
        self.gh.call("POST", f"repos/{{repo}}/issues/{number}/comments", {"body": f"**Merge slot:** {text}"})

    def drop_ref(self, ref):
        try:
            self.gh.call("DELETE", f"repos/{{repo}}/git/refs/heads/{ref}")
        except GitHubError as error:
            if error.status not in (404, 422):
                raise

    def leave(self, pull, why):
        number = pull["number"]
        self.log(f"#{number} leaves the slot: {why}")
        self.left[number] = (pull["head"]["sha"], self.label_times.get(number))
        try:
            self.gh.call("DELETE", f"repos/{{repo}}/issues/{number}/labels/{LABEL}")
        except GitHubError as error:
            if error.status != 404:
                raise
        self.label_times.pop(number, None)
        self.comment(number, f"{why}\n\nIt left the slot (label `{LABEL}` removed). When it's fixed, add the label "
                             "again; don't merge it yourself.")
        return "left"

    def point(self, ref, sha):
        """Moves (or creates) a branch to a commit."""
        try:
            self.gh.call("PATCH", f"repos/{{repo}}/git/refs/heads/{ref}", {"sha": sha, "force": True})
        except GitHubError as error:
            if error.status not in (404, 422):
                raise
            self.gh.call("POST", "repos/{repo}/git/refs", {"ref": f"refs/heads/{ref}", "sha": sha})

    def test_merge(self, number, base, head):
        """The merge of head into base on merge-slot/pr-<N>, built once per base and head: (sha, tree). "conflict"
        when they conflict, "contained" when main already has the head."""
        ref = f"{SLOT_PREFIX}{number}"
        try:
            current = self.gh.call("GET", f"repos/{{repo}}/git/ref/heads/{ref}")["object"]["sha"]
            commit = self.gh.call("GET", f"repos/{{repo}}/commits/{current}")
            if [p["sha"] for p in commit["parents"]] == [base, head]:
                return current, commit["commit"]["tree"]["sha"]
        except GitHubError as error:
            if error.status != 404:
                raise
        self.point(ref, base)
        try:
            made = self.gh.call("POST", "repos/{repo}/merges", {
                "base": ref, "head": head, "commit_message": f"Merge slot test: #{number} {head[:10]} on main {base[:10]}"})
        except GitHubError as error:
            if error.status == 409:
                return "conflict", str(error)
            raise
        if not made:  # 204: nothing to merge
            return "contained"
        return made["sha"], made["commit"]["tree"]["sha"]

    def test(self, pull, merge_sha):
        """Dispatches checks.yml on merge-slot/pr-<N>, which test_merge left at the merge commit."""
        number = pull["number"]
        ref = f"{SLOT_PREFIX}{number}"
        self.gh.call("POST", f"repos/{{repo}}/actions/workflows/{WORKFLOW}/dispatches", {"ref": ref})
        self.dispatched[(number, merge_sha)] = self.now()
        self.log(f"#{number}: testing {merge_sha} on {ref}")
        return "testing"

    def merge(self, pull, head, base, proof):
        number = pull["number"]
        if self.main_sha() != base:
            self.log(f"#{number}: main moved before the merge, testing again")
            return "moved"
        try:
            result = self.gh.call("PUT", f"repos/{{repo}}/pulls/{number}/merge", {"merge_method": "merge", "sha": head})
        except GitHubError as error:
            if error.status not in (405, 409):  # 409: the head changed; 405: GitHub refused (a rule, a check)
                raise
            self.refusals[number] = self.refusals.get(number, 0) + 1
            if self.refusals[number] >= 3:
                self.refusals.pop(number)
                return self.leave(pull, f"GitHub refused the merge three times: {error}")
            self.log(f"#{number}: GitHub refused the merge ({error}), trying again")
            return "moved"
        self.refusals.pop(number, None)
        self.gh.call("POST", f"repos/{{repo}}/actions/workflows/{WORKFLOW}/dispatches", {"ref": "main"})
        self.drop_ref(f"{SLOT_PREFIX}{number}")
        if (result or {}).get("merged") and pull["head"]["repo"]["full_name"] == pull["base"]["repo"]["full_name"]:
            self.drop_ref(pull["head"]["ref"])  # GitHub confirmed the merge in its answer
        self.label_times.pop(number, None)
        self.comment(number, f"merged after run {proof} tested this pull request on main `{base[:10]}`. "
                             "The branch is deleted; checks.yml runs on main to refresh the build cache.")
        self.log(f"#{number} merged")
        return "merged"

    def advance(self, pull):
        """Moves one pull request as far as it can go now."""
        number = pull["number"]
        pull = self.gh.call("GET", f"repos/{{repo}}/pulls/{number}")
        if pull["state"] != "open" or not any(label["name"] == LABEL for label in pull["labels"]):
            return "gone"
        if pull["head"]["repo"]["full_name"] != pull["base"]["repo"]["full_name"] or pull["base"]["ref"] != "main":
            return self.leave(pull, "the slot merges branches of this repository into main only.")
        if pull["draft"]:
            return self.leave(pull, "it is a draft: mark it ready for review first.")
        head = pull["head"]["sha"]
        workflow_files = self.workflow_files(number, head)
        if workflow_files:
            return self.leave(pull, f"it changes {', '.join(f'`{f}`' for f in workflow_files)}. GitHub doesn't let the "
                                    "slot's workflow token create or update workflow files, so it can neither test-merge "
                                    "nor merge this pull request. Merge it by hand: merge origin/main into the branch, "
                                    f"push, and once check-all is green run `gh pr merge {number} --merge` at once (if "
                                    "main moved meanwhile, merge main again first). Don't add the label again.")
        check = self.head_check(head)
        if check is None or check[0] != "completed":
            return "waiting"
        if check[1] != "success":
            return self.leave(pull, f"check-all on the head `{head[:10]}` is {check[1]} ({check[2]}). Fix it; if "
                                    "it's a known flake, re-run that run's failed jobs (`gh run rerun <run> --failed`) "
                                    "and add the label once it's green.")
        base = self.main_sha()
        built = self.test_merge(number, base, head)
        if isinstance(built, tuple) and built[0] == "conflict":
            return self.leave(pull, "it conflicts with main: merge origin/main into the branch, resolve, push, wait "
                                    f"for check-all to be green. (GitHub: {built[1]})")
        if built == "contained":
            return self.leave(pull, f"main `{base[:10]}` already contains its head `{head[:10]}`: nothing to merge.")
        merge_sha, tree = built
        proof = self.verified(tree, head, base)
        if proof:
            return self.merge(pull, head, base, proof)
        run = self.slot_run(number, merge_sha)
        if run is None:
            sent = self.dispatched.get((number, merge_sha))
            if sent and self.now() - sent < dt.timedelta(minutes=10):
                return "testing"  # dispatched; GitHub lists the run a little later
            return self.test(pull, merge_sha)
        if run["status"] != "completed":
            if self.now() - when(run.get("run_started_at") or run["created_at"]) > TEST_TIMEOUT:
                return self.leave(pull, f"the test run {run['html_url']} hasn't finished in "
                                        f"{TEST_TIMEOUT.seconds // 3600} hours.")
            return "testing"
        if run["conclusion"] == "success" and self.run_is_green(run["id"], head, base):
            return self.merge(pull, head, base, run["html_url"])
        return self.leave(pull, f"the run {run['html_url']} that tested this pull request on main `{base[:10]}` "
                                f"ended {run['conclusion']}. Fix it; if it's a known flake, re-run its failed jobs "
                                f"(`gh run rerun {run['id']} --failed`) and add the label again: a green re-run of "
                                "that run counts while main hasn't moved.")

    def sweep(self):
        """Deletes merge-slot/pr-<N> branches of pull requests that are no longer open."""
        open_numbers = {p["number"] for p in self.gh.call("GET", "repos/{repo}/pulls?state=open&per_page=100")}
        for ref in self.gh.call("GET", f"repos/{{repo}}/git/matching-refs/heads/{SLOT_PREFIX}") or []:
            name = ref["ref"][len("refs/heads/"):]
            if not name[len(SLOT_PREFIX):].isdigit() or int(name[len(SLOT_PREFIX):]) not in open_numbers:
                self.drop_ref(name)

    def serve(self, deadline, poll=90):
        """Works the queue until it's empty or the deadline passes."""
        self.sweep()
        busy = 0  # passes in a row without sleeping
        while True:
            queue = self.queue()
            if not queue:
                self.log("the queue is empty")
                return
            moved = False
            waiting = [p for p in queue
                       if self.left.get(p["number"]) != (p["head"]["sha"], self.label_times[p["number"]])]
            if not waiting:
                self.log("only pull requests that left are labeled (their label couldn't be removed)")
                return
            for pull in waiting:  # one that left comes back with a new head or a new label
                state = self.advance(pull)
                if state in ("merged", "left", "gone", "moved"):
                    moved = True
                    break
                if state == "testing":
                    break  # the slot is held until this test ends
            if moved and busy < 20:
                busy += 1
                continue
            busy = 0
            if self.now() >= deadline:
                self.log("deadline reached; the next run of the workflow carries on")
                return
            self.sleep(poll)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--minutes", type=float, default=320, help="stop after this long (the job has 340)")
    args = parser.parse_args()
    slot = Slot(GitHub(args.repo))
    slot.serve(slot.now() + dt.timedelta(minutes=args.minutes))


if __name__ == "__main__":
    try:
        main()
    except GitHubError as error:
        sys.exit(f"✗ merge-slot: {error}")

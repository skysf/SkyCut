#!/usr/bin/env python3
"""Re-runs the failed jobs of a checks.yml run when GitHub's infrastructure failed them, never when a check did
(docs/build/build-and-packaging.md "CI", "Automatic re-runs").

A run qualifies only when every job that failed or was cancelled
  - carries one of GitHub's own messages for a job that never got a runner or lost it (INFRA), and none that means a
    step failed, a timeout, a newer push or a person cancelling (NOT_INFRA);
  - started no step but the setup steps before the first check (SETUP_STEPS), and at most one of them didn't
    succeed: the last one, cut off;
except the summary job check-all, which may fail at its gate "All shards passed" alone (it only reports the shards).
At most MAX_RERUNS re-runs per run, and only while the run tests its branch's head and is that branch's newest checks
run: a re-run of a superseded pull request run would cancel the newer one (same concurrency group).

.github/workflows/rerun-infra.yml runs this when a checks run completes; scripts/merge-slot.py asks it about the runs
it waits on and re-runs them through it. checks/MergeSlot/InfraRerunCases.py tests it against a fake GitHub and pins
SETUP_STEPS and the workflow.

Usage: scripts/ci-infra-rerun.py --repo OWNER/REPO --run RUN_ID [--attempt N] [--dry-run]
  --attempt  the attempt the workflow_run event reported; a run re-run since then is left alone
  --dry-run  print the verdict and re-run nothing (with --attempt: also that attempt's own verdict)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse

WORKFLOW = "checks.yml"
WORKFLOW_PATH = ".github/workflows/checks.yml"
MAX_RERUNS = 2  # attempts 1 and 2 may be re-run: a run ends at attempt 3 at most

# GitHub's annotations on a job that never got a runner or lost it.
INFRA = (
    "was not acquired by Runner",  # "The job was not acquired by Runner of type hosted even after multiple attempts"
    "lost communication with the server",  # "The hosted runner: … lost communication with the server. …"
    "runner has received a shutdown signal",  # "The runner has received a shutdown signal. …"
)
# Annotations that make a failure not GitHub's, whatever else the job says.
NOT_INFRA = (
    "Process completed with exit code",  # a step failed
    "exceeded the maximum execution time",  # a timeout, inside a check or not
    "Canceling since a higher priority waiting request",  # a newer push or merge superseded the run
    "was canceled by",  # "The run was canceled by @…": a person
)
# Per job of checks.yml, the steps before its first check step, GitHub's own "Set up job" included. A job that
# started any other step may have tested something, so it never qualifies. InfraRerunCases.py pins these to the file.
SETUP_STEPS = {
    "shard": ("Set up job", "Run actions/checkout@v4", "Toolchain versions (diagnostics)",
              "Classify changes (docs only?)", "Already verified? (main only, same tree as the pull request's green run)",
              "Stable file times (content-derived)", "Restore SwiftPM build products", "Cache vendor/ffmpeg",
              "Fetch ffmpeg (on cache miss)"),
    "check-all": ("Set up job", "Run actions/checkout@v4", "Set up Node.js for website checks"),
}
SUMMARY_JOB, SUMMARY_GATE = "check-all", "All shards passed"
PASSED = ("success", "skipped", "neutral")


class GitHubError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


class GitHub:
    """`gh api` with JSON in and out; {repo} in a path is this repository."""

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


class Verdict:
    """kind: green, pending (still running or re-run since), rerun (qualifies), rerunning (this call re-ran it),
    exhausted (GitHub's fault, but MAX_RERUNS used up), stale (superseded or a fork's) or real (a check's fault)."""

    def __init__(self, kind, why, run):
        self.kind, self.why, self.run = kind, why, run

    def __repr__(self):
        return f"{self.kind}: {self.why}"


def step_ran(step):
    return step.get("status") == "in_progress" or step.get("conclusion") not in (None, "skipped")


def job_verdict(job, messages):
    """None when the job passed; else (kind, why) with kind infra, summary (check-all failing at its gate alone) or
    real."""
    if job.get("conclusion") in PASSED:
        return None
    name = job["name"]
    ran = [s for s in job.get("steps") or [] if step_ran(s)]
    broken = [i for i, s in enumerate(ran) if s.get("conclusion") != "success"]
    if name == SUMMARY_JOB and job.get("conclusion") == "failure" and [ran[i]["name"] for i in broken] == [SUMMARY_GATE]:
        return "summary", f"{name} failed at {SUMMARY_GATE!r} only"
    if broken and broken != [len(ran) - 1]:  # a step failed and the job went on: the step's own failure
        return "real", f"{name}: step {ran[broken[0]]['name']!r} {ran[broken[0]].get('conclusion') or 'failed'}"
    setup = SETUP_STEPS.get("shard" if re.fullmatch(r"shard \d+/\d+", name) else name, ("Set up job",))
    checks = [s["name"] for s in ran if s["name"] not in setup]
    if checks:
        return "real", f"{name}: the step {checks[0]!r} had started"
    said = [m for m in messages if any(sign in m for sign in NOT_INFRA)]
    if said:
        return "real", f"{name}: {said[0]}"
    said = [m for m in messages if any(sign in m for sign in INFRA)]
    if not said:
        return "real", f"{name} {job.get('conclusion')} without a message from GitHub's infrastructure"
    return "infra", f"{name}: {said[0]}"


def attempt_verdict(gh, run_id, attempt):
    """(kind, why) for one attempt's jobs: infra (every failed job GitHub's fault), real, or none (nothing failed)."""
    jobs = gh.call("GET", f"repos/{{repo}}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")["jobs"]
    found = []
    for job in jobs:
        if job.get("conclusion") in PASSED:
            continue
        notes = gh.call("GET", f"repos/{{repo}}/check-runs/{job['id']}/annotations?per_page=100") or []
        found.append(job_verdict(job, [n.get("message") or "" for n in notes]))
    real = [why for kind, why in found if kind == "real"]
    if real:
        return "real", real[0]
    infra = [why for kind, why in found if kind == "infra"]
    if not infra:
        return ("real", "no job failed because of GitHub's infrastructure") if found else ("none", "nothing failed")
    return "infra", infra[0] + (f" (and {len(infra) - 1} more job(s))" if len(infra) > 1 else "")


def superseded(gh, run):
    """Why re-running the run would test the wrong thing or cancel a newer run, or None."""
    if (run.get("head_repository") or {}).get("full_name") != run["repository"]["full_name"]:
        return "it tests a fork's branch"
    branch = run["head_branch"]
    try:
        tip = gh.call("GET", f"repos/{{repo}}/git/ref/heads/{branch}")["object"]["sha"]
    except GitHubError as error:
        if error.status != 404:
            raise
        return f"the branch {branch} is gone"
    if tip != run["head_sha"]:
        return f"{branch} has moved on to {tip[:10]}"
    newest = gh.call("GET", f"repos/{{repo}}/actions/workflows/{WORKFLOW}/runs"
                            f"?branch={urllib.parse.quote(branch, safe='')}&per_page=1")["workflow_runs"]
    if newest and newest[0]["id"] != run["id"]:
        return f"run {newest[0]['id']} is newer on {branch}"
    return None


def decide(gh, run_id, attempt=None):
    """The verdict for the run's latest attempt; with attempt, a run re-run since then is pending."""
    run = gh.call("GET", f"repos/{{repo}}/actions/runs/{run_id}")
    if attempt is not None and run["run_attempt"] != attempt:
        return Verdict("pending", f"re-run since: attempt {run['run_attempt']}", run)
    if run["status"] != "completed":
        return Verdict("pending", f"attempt {run['run_attempt']} is {run['status']}", run)
    if run["conclusion"] == "success":
        return Verdict("green", "it passed", run)
    if run["path"] != WORKFLOW_PATH:
        return Verdict("real", f"{run['path']} is not the checks workflow", run)
    kind, why = attempt_verdict(gh, run_id, run["run_attempt"])
    if kind != "infra":
        return Verdict("real", why if kind == "real" else f"it ended {run['conclusion']} with no failed job", run)
    if run["run_attempt"] > MAX_RERUNS:
        return Verdict("exhausted", f"{why}; attempt {run['run_attempt']}, already re-run {MAX_RERUNS} times", run)
    stale = superseded(gh, run)
    if stale:
        return Verdict("stale", f"{why}; not re-run: {stale}", run)
    return Verdict("rerun", why, run)


def rerun(gh, verdict):
    """Re-runs the failed jobs (and check-all, which needs them) of a run decide() said qualifies."""
    run = verdict.run
    try:
        gh.call("POST", f"repos/{{repo}}/actions/runs/{run['id']}/rerun-failed-jobs", {})
    except GitHubError:
        now = gh.call("GET", f"repos/{{repo}}/actions/runs/{run['id']}")
        if now["status"] != "completed" or now["run_attempt"] != run["run_attempt"]:
            return Verdict("pending", f"re-run already: attempt {now['run_attempt']}", now)
        raise
    return Verdict("rerunning", f"{verdict.why}; re-running attempt {run['run_attempt']}'s failed jobs", run)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run", type=int, required=True)
    parser.add_argument("--attempt", type=int)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    gh = GitHub(args.repo)
    if args.dry_run:
        if args.attempt:
            print(f"attempt {args.attempt}: {attempt_verdict(gh, args.run, args.attempt)}")
        print(f"run {args.run} now: {decide(gh, args.run)}")
        return
    verdict = decide(gh, args.run, args.attempt)
    if verdict.kind == "rerun":
        verdict = rerun(gh, verdict)
    line = f"checks run {args.run} (attempt {verdict.run['run_attempt']}): {verdict}"
    print(line)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(line + "\n")


if __name__ == "__main__":
    try:
        main()
    except GitHubError as error:
        sys.exit(f"✗ ci-infra-rerun: {error}")

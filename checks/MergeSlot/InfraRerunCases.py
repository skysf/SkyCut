"""Cases for the automatic re-runs of runs GitHub's infrastructure failed (scripts/ci-infra-rerun.py,
.github/workflows/rerun-infra.yml) and the merge slot's use of them. MergeSlotChecks.py runs them with its check().

1. Verdicts on runs whose jobs look like GitHub's (FakeJobs.py: checks.yml's own step names, GitHub's own messages):
   only jobs that never got a runner, or lost it during setup before any check step started, are re-run. A failed or
   timed-out check, a failed setup step, a newer push, a person, a fork, a moved branch or used-up attempts never are,
   alone or next to GitHub's failures; nothing but rerun() ever asks GitHub to re-run.
2. The merge slot re-runs such a run instead of sending the pull request back and waits for it; it sends the pull
   request back when the re-runs are used up, the failure is a check's, or GitHub refuses the re-run.
3. Pins: SETUP_STEPS are steps of checks.yml whose commands run no check; rerun-infra.yml's trigger, permissions,
   main-only checkout and arguments.
"""
import os
import re

from FakeGitHub import FakeGitHub
from FakeJobs import (CANCELED, CHECKS_YML, EXIT, LOST, NOT_ACQUIRED, ROOT, SHUTDOWN, SUPERSEDED, TIMEOUT, Jobs,
                      workflow_steps)

J = Jobs()
SHARDS = [f"shard {n}/5" for n in range(1, 6)]


def rest(*jobs, gate=True):
    """These jobs, green ones for the other shards, and check-all failing at its gate."""
    named = {job["name"] for job, _ in jobs}
    return list(jobs) + [J.ok(s) for s in SHARDS if s not in named] + ([J.gate()] if gate else [])


QUALIFY = (
    ("a shard never got a runner (run 44561816873, 2026-11-19)", rest(J.not_acquired("shard 1/5"))),
    ("two shards never got a runner", rest(J.not_acquired("shard 1/5"), J.not_acquired("shard 4/5"))),
    ("the runner was lost restoring the build cache", rest(J.lost("shard 2/5", "Restore SwiftPM build products"))),
    ("the runner was lost during checkout, its step still in progress",
     rest(J.lost("shard 3/5", "Run actions/checkout@v4", cut="in_progress"))),
    ("the runner shut down fetching ffmpeg", rest(J.lost("shard 5/5", "Fetch ffmpeg (on cache miss)", message=SHUTDOWN))),
    ("check-all itself never got a runner", [J.ok(s) for s in SHARDS] + [J.not_acquired("check-all")]),
)
NEVER = (
    ("a check failed", rest(J.failed("shard 1/5", "Run checks (shard 1 of 5)"))),
    ("the App didn't build", rest(J.failed("shard 1/5", "Build app (errors visible here)"))),
    ("the playback benchmark failed", rest(J.failed("shard 1/5", "Playback start benchmark"))),
    ("a check failed while another shard never got a runner",
     rest(J.failed("shard 2/5", "Run checks (shard 2 of 5)"), J.not_acquired("shard 1/5"))),
    ("the runner was lost during a check", rest(J.lost("shard 1/5", "Run checks (shard 1 of 5)"))),
    ("the runner was lost during the App build", rest(J.lost("shard 1/5", "Build app (errors visible here)"))),
    ("the runner was lost during the docs-only scan guards", rest(J.lost("shard 1/5", "Scan guards only (docs-only change)"))),
    ("the runner was lost during the perf ratchet", rest(J.lost("shard 1/5", "Preview performance ratchet"))),
    ("a job timed out inside a check", rest(J.failed("shard 1/5", "Run checks (shard 1 of 5)", "cancelled", (TIMEOUT, CANCELED)))),
    ("a job timed out restoring the cache", rest(J.failed("shard 1/5", "Restore SwiftPM build products", "cancelled",
                                                          (TIMEOUT, CANCELED)))),
    ("a setup step failed by itself", rest(J.failed("shard 1/5", "Classify changes (docs only?)"))),
    ("a setup step cut off, but the job went on", rest(J.failed("shard 1/5", "Stable file times (content-derived)",
                                                                "cancelled", (CANCELED,)))),
    ("a setup step failed, then the runner was lost in the next", rest(J.job("shard 1/5", "failure", [
        ("Set up job", "completed", "success"), ("Run actions/checkout@v4", "completed", "failure"),
        ("Toolchain versions (diagnostics)", "completed", "cancelled")], [LOST]))),
    ("a newer push cancelled the run", J.run("superseded")),
    ("a person cancelled the run", J.run("cancelled")),
    ("GitHub's message next to a failed step's", rest(J.job("shard 1/5", "cancelled", [], [NOT_ACQUIRED, EXIT]))),
    ("GitHub's message on a superseded job", rest(J.job("shard 1/5", "cancelled", [], [NOT_ACQUIRED, SUPERSEDED]))),
    ("a job failed without any message", rest(J.job("shard 1/5", "failure", [], []))),
    ("a shard never got a runner, and the website failed", rest(J.not_acquired("shard 1/5"), gate=False) + [J.gate("failure")]),
    ("a shard never got a runner, the website and the gate failed", rest(J.not_acquired("shard 1/5"), gate=False) + [J.job(
        "check-all", "failure", [(s, "completed", "failure" if s in ("Test and build the website", "All shards passed")
                                  else "success") for s in J.summary], [EXIT])]),
    ("cut off in setup with only GitHub's generic cancel message", rest(J.lost("shard 1/5", "Cache vendor/ffmpeg",
                                                                              message=CANCELED))),
    ("check-all failed at its gate while every shard passed", rest()),
)


def world(infra, jobs, attempt=1):
    gh = FakeGitHub(infra.GitHubError)
    gh.open_pull(1)
    run = gh.pr_run(1, jobs=jobs)
    if attempt > 1:
        gh.runs[run]["run_attempt"] = attempt
        gh.set_jobs(run, attempt, jobs)
    return gh, run


def verdicts(check, infra):
    for name, jobs in QUALIFY:
        gh, run = world(infra, jobs)
        verdict = infra.decide(gh, run)
        check(f"re-run: {name}", verdict.kind == "rerun" and not gh.reruns, verdict)
        done = infra.rerun(gh, verdict)
        check(f"re-run: {name}: failed jobs re-run once", done.kind == "rerunning" and gh.reruns == [run]
              and gh.runs[run]["run_attempt"] == 2, (done, gh.reruns))
    for name, jobs in NEVER:
        gh, run = world(infra, jobs)
        verdict = infra.decide(gh, run)
        check(f"never re-run: {name}", verdict.kind == "real" and not gh.reruns, verdict)
    infra_jobs = QUALIFY[0][1]
    for attempt, kind in ((2, "rerun"), (3, "exhausted"), (4, "exhausted")):
        gh, run = world(infra, infra_jobs, attempt)
        verdict = infra.decide(gh, run)
        check(f"attempt {attempt}: {kind} (at most {infra.MAX_RERUNS} re-runs)", verdict.kind == kind, verdict)
    check("at most two re-runs", infra.MAX_RERUNS == 2, infra.MAX_RERUNS)

    def moved(gh, run):
        gh.pulls[1]["head"]["sha"] = gh.commit([gh.main], "tree-head-1b")

    def newer(gh, run):
        gh.pr_run(1)

    def fork(gh, run):
        gh.runs[run]["head_repository"] = {"full_name": "fork/r"}

    def gone(gh, run):
        gh.pulls[1]["state"] = "closed"

    def running(gh, run):
        gh.runs[run]["status"] = "in_progress"

    def other(gh, run):
        gh.runs[run]["path"] = ".github/workflows/other.yml"

    for name, change, kind in (("the branch moved on", moved, "stale"), ("a newer run on the branch", newer, "stale"),
                               ("a fork's run", fork, "stale"), ("the branch is gone", gone, "stale"),
                               ("still running", running, "pending"), ("another workflow's run", other, "real")):
        gh, run = world(infra, infra_jobs)
        change(gh, run)
        verdict = infra.decide(gh, run)
        check(f"{name}: {kind}", verdict.kind == kind and not gh.reruns, verdict)
    gh, run = world(infra, J.run("success"))
    check("a green run: green", infra.decide(gh, run).kind == "green", gh.runs[run])
    gh, run = world(infra, infra_jobs)
    gh.call("POST", f"repos/{{repo}}/actions/runs/{run}/rerun-failed-jobs", {})
    check("the event's attempt was re-run since: pending",
          infra.decide(gh, run, attempt=1).kind == "pending" and gh.reruns == [run], gh.reruns)
    gh.plans[run] = ["infra"]
    gh.tick(60)  # that re-run failed the same way: its own event decides, not the late one for attempt 1
    check("a late event for an attempt already re-run and finished: pending, attempt 2's event re-runs it",
          infra.decide(gh, run, attempt=1).kind == "pending" and infra.decide(gh, run, attempt=2).kind == "rerun",
          gh.runs[run])
    gh, run = world(infra, infra_jobs)
    verdict = infra.decide(gh, run)
    gh.call("POST", f"repos/{{repo}}/actions/runs/{run}/rerun-failed-jobs", {})  # the workflow got there first
    check("two re-runners race: one re-run, the other pending",
          infra.rerun(gh, verdict).kind == "pending" and gh.reruns == [run], gh.reruns)
    gh, run = world(infra, infra_jobs)
    gh.refuse_rerun = True
    try:
        infra.rerun(gh, infra.decide(gh, run))
        refused = False
    except infra.GitHubError:
        refused = True
    check("GitHub refuses the re-run of a completed run: an error, not a silent pass", refused, gh.reruns)


def slot_cases(check, world_of, serve, never_merged_untested):
    gh, slot = world_of()
    gh.open_pull(1)
    run = gh.pr_run(1, plan=["infra", "success"])
    serve(slot, gh)
    check("slot: check-all red because a shard never got a runner: re-run, then merged",
          [n for n, _ in gh.merged] == [1] and gh.reruns == [run]
          and not any("left the slot" in c for c in gh.comments.get(1, [])), (gh.merged, gh.reruns, gh.comments))
    never_merged_untested("slot: infra head", gh)

    gh, slot = world_of()
    gh.open_pull(1)
    gh.human_merge()
    gh.outcomes["merge-slot/pr-1"] = "infra"  # then green
    serve(slot, gh)
    test = [r["id"] for r in gh.runs.values() if r["head_branch"] == "merge-slot/pr-1"]
    check("slot: its test run never got a runner: re-run in place (no second dispatch), then merged",
          [n for n, _ in gh.merged] == [1] and gh.dispatches.count("merge-slot/pr-1") == 1 and gh.reruns == test,
          (gh.merged, gh.dispatches, gh.reruns))
    never_merged_untested("slot: infra test", gh)

    gh, slot = world_of()
    gh.open_pull(1)
    run = gh.pr_run(1, plan=["infra"])  # every attempt
    serve(slot, gh)
    check("slot: GitHub fails it on every attempt: two re-runs, then back with the by-hand re-run",
          not gh.merged and gh.reruns == [run, run]
          and any("GitHub's runners" in c and f"gh run rerun {run} --failed" in c for c in gh.comments.get(1, [])),
          (gh.reruns, gh.comments))

    gh, slot = world_of()
    gh.open_pull(1)
    run = gh.pr_run(1, plan=["failure", "success"])
    serve(slot, gh)
    check("slot: a check failed: back at once, never re-run",
          not gh.merged and not gh.reruns and any("check-all on the head" in c for c in gh.comments.get(1, [])),
          (gh.reruns, gh.comments))

    gh, slot = world_of()
    gh.open_pull(1)
    run = gh.pr_run(1, plan=["infra", "success"])
    gh.call("POST", f"repos/{{repo}}/actions/runs/{run}/rerun-failed-jobs", {})  # rerun-infra.yml was first
    serve(slot, gh)
    check("slot: already being re-run: waits, no second re-run, merged",
          [n for n, _ in gh.merged] == [1] and gh.reruns == [run], (gh.merged, gh.reruns))

    gh, slot = world_of()
    gh.open_pull(1)
    gh.refuse_rerun = True
    gh.pr_run(1, plan=["infra", "success"])
    serve(slot, gh)
    check("slot: GitHub refuses the re-run: back with the usual message",
          not gh.merged and any("check-all on the head" in c for c in gh.comments.get(1, [])), gh.comments)


def pins(check, infra):
    shown = workflow_steps(CHECKS_YML, with_commands=True)
    for job, setup in infra.SETUP_STEPS.items():
        steps = dict(shown.get(job, []))
        names = [name for name, _ in shown.get(job, [])]
        check(f"SETUP_STEPS[{job}] starts with GitHub's own 'Set up job'", setup[:1] == ("Set up job",), setup)
        missing = [s for s in setup[1:] if s not in steps]
        check(f"SETUP_STEPS[{job}] are steps of checks.yml's {job} job (rename both together)", not missing, missing)
        order = [names.index(s) for s in setup[1:] if s in steps]
        check(f"SETUP_STEPS[{job}] in checks.yml's order", order == sorted(order), order)
        for name in setup[1:]:
            command = steps.get(name, "")
            check(f"setup step {name!r} runs no check", not re.search(
                r"check-|swift (build|run|test)|npm|(^|[\s;&|])test\s", command), command)
    names = workflow_steps(CHECKS_YML)
    check("the check steps are not setup steps", not ({"Scan guards only (docs-only change)", "Build app (errors visible here)",
                                                       "Playback start benchmark", "Run checks (shard 1 of 5)",
                                                       "Preview performance ratchet"} & set(infra.SETUP_STEPS["shard"]))
          and "Test and build the website" not in infra.SETUP_STEPS["check-all"] and names.get("shard"), names.get("shard"))
    checks_code = "\n".join(l for l in open(CHECKS_YML, encoding="utf-8").read().splitlines() if not l.lstrip().startswith("#"))
    check("checks.yml is named checks (rerun-infra.yml's workflows filter)", re.search(r"^name: checks$", checks_code, re.M), "name:")
    path = os.path.join(ROOT, ".github", "workflows", "rerun-infra.yml")
    code = "\n".join(l for l in open(path, encoding="utf-8").read().splitlines() if not l.lstrip().startswith("#")) + "\n"
    for want, why in (
        (r"\non:\n  workflow_run:\n    workflows: \[checks\]\n    types: \[completed\]\n", "runs when a checks run completes"),
        (r"if: github\.event\.workflow_run\.conclusion != 'success' && "
         r"github\.event\.workflow_run\.head_repository\.full_name == github\.repository\n", "red runs of this repository only"),
        (r"ref: main\n\s+persist-credentials: false", "checks out main, never the pull request's code"),
        (r'run: python3 -I -B scripts/ci-infra-rerun\.py --repo "\$\{\{ github\.repository \}\}" --run '
         r'"\$\{\{ github\.event\.workflow_run\.id \}\}" --attempt "\$\{\{ github\.event\.workflow_run\.run_attempt \}\}"\n',
         "the script, with the run and the attempt that completed"),
    ):
        check(f"rerun-infra.yml: {why}", re.search(want, code), want)
    for forbidden in ("head_branch", "head_sha", "pull_requests", "github.head_ref", "pull_request_target", "cancel-in-progress: true"):
        check(f"rerun-infra.yml must not use {forbidden}", forbidden not in code, forbidden)
    permissions = re.search(r"\npermissions:\n((?:  .*\n)+)", code)
    granted = dict(re.findall(r"  ([a-z-]+): (\w+)", permissions.group(1))) if permissions else {}
    check("rerun-infra.yml permissions", granted == {"contents": "read", "actions": "write", "checks": "read"}, granted)


def run_all(check, slot_module, world_of, serve, never_merged_untested):
    verdicts(check, slot_module.infra)
    slot_cases(check, world_of, serve, never_merged_untested)
    pins(check, slot_module.infra)

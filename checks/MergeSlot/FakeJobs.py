"""Job records the way GitHub's jobs API shows checks.yml's jobs, with their annotations, for InfraRerunCases.py and
MergeSlotChecks.py. Step names come from the real .github/workflows/checks.yml, so a renamed or moved step changes
what the checks see. The messages are GitHub's own, copied from real runs (2026-11-19) or GitHub's docs.
"""
import itertools
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHECKS_YML = os.path.join(ROOT, ".github", "workflows", "checks.yml")

NOT_ACQUIRED = "The job was not acquired by Runner of type hosted even after multiple attempts"  # run 44561816873
CAPACITY = "Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times."
LOST = ("The hosted runner: GitHub Actions 1000010601 lost communication with the server. Anything in your workflow "
        "that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error.")
SHUTDOWN = ("The runner has received a shutdown signal. This can happen when the runner service is stopped, or a "
            "manually started runner is canceled.")
EXIT = "Process completed with exit code 1."
TIMEOUT = "The job has exceeded the maximum execution time of 30m0s"
CANCELED = "The operation was canceled."
SUPERSEDED = "Canceling since a higher priority waiting request for checks-1 exists"
PERSON = "The run was canceled by @someone."
NODE = "Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24."
# Steps a pull request's code run skips (their if:), as GitHub lists them: skipped, so never "started". In shards 2-5
# also the steps only shard 1 runs.
SKIPPED = {"Scan guards only (docs-only change)", "Fetch ffmpeg (on cache miss)",
           "Save SwiftPM build products (main only, after the App build)", "Name the verified tree",
           "Leave the verified-tree marker"}
SHARD_1_ONLY = {"Build app (errors visible here)", "Playback start benchmark", "Upload playback start samples",
                "Preview performance ratchet", "Upload preview performance results"}
IDS = itertools.count(9000)  # job ids, unique across every world


def workflow_steps(path=CHECKS_YML, with_commands=False):
    """{job id: [step names as GitHub shows them, in order]}: `name:`, else "Run <uses>", matrix values filled in.
    with_commands: [(name, the step's `run:` text)] instead."""
    jobs, job, steps_at, current, in_run = {}, None, False, None, False
    for line in open(path, encoding="utf-8"):
        if line.lstrip().startswith("#"):
            continue
        if found := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
            job, steps_at, current = found.group(1), False, None
            jobs[job] = []
        elif job and re.match(r"^    steps:\s*$", line):
            steps_at = True
        elif steps_at and (found := re.match(r"^      - ([a-z-]+): ?(.*)$", line)):
            current = {found.group(1): found.group(2).strip(), "run_text": ""}
            jobs[job].append(current)
            in_run = found.group(1) == "run"
            current["run_text"] = found.group(2) if in_run else ""
        elif steps_at and current is not None and (found := re.match(r"^        ([a-z-]+): ?(.*)$", line)):
            current[found.group(1)] = found.group(2).strip()
            in_run = found.group(1) == "run"
            if in_run:
                current["run_text"] += found.group(2)
        elif in_run and current is not None and line.startswith("          "):
            current["run_text"] += "\n" + line.strip()
    shown = {}
    for job, steps in jobs.items():
        listed = []
        for step in steps:
            name = step.get("name") or f"Run {step.get('uses', step.get('run', ''))}"
            name = name.replace("${{ matrix.shard }}", "1").replace("${{ strategy.job-total }}", "5")
            listed.append((name, step["run_text"]) if with_commands else name)
        shown[job] = listed
    return shown


class Jobs:
    """Builds jobs: each is (record, annotation messages). ids are unique across one world."""

    def __init__(self, path=CHECKS_YML):
        steps = workflow_steps(path)
        self.shard = ["Set up job"] + steps["shard"] + ["Post Run actions/checkout@v4", "Complete job"]
        self.summary = ["Set up job"] + steps["check-all"] + ["Post Run actions/checkout@v4", "Complete job"]

    def job(self, name, conclusion, steps, messages):
        return {"id": next(IDS), "name": name, "status": "completed", "conclusion": conclusion,
                "runner_id": 0 if not steps else 1000010601,
                "steps": [{"name": n, "status": s, "conclusion": c} for n, s, c in steps]}, list(messages)

    def names(self, name):
        if name == "check-all":
            return self.summary
        number = re.fullmatch(r"shard (\d+)/5", name).group(1)
        return [s.replace("(shard 1 of 5)", f"(shard {number} of 5)") for s in self.shard]

    def passed(self, name, step):
        """How a step that ran before the end ended in a pull request's code run: success, or skipped by its if:."""
        skipped = step in SKIPPED or (name != "shard 1/5" and step in SHARD_1_ONLY)
        return (step, "completed", "skipped" if skipped else "success")

    def ok(self, name):
        return self.job(name, "success", [self.passed(name, s) for s in self.names(name)], [NODE])

    def not_acquired(self, name):
        return self.job(name, "cancelled", [], [NOT_ACQUIRED, CAPACITY])

    def lost(self, name, at, cut="cancelled", message=LOST):
        """The runner disappears during step `at`: that step is cut off and nothing runs after it."""
        names = self.names(name)
        upto = names.index(at)
        steps = [self.passed(name, s) for s in names[:upto]]
        steps.append((at, "in_progress", None) if cut == "in_progress" else (at, "completed", cut))
        return self.job(name, "failure", steps + [(s, "queued", None) for s in names[upto + 1:]], [message])

    def failed(self, name, at, conclusion="failure", messages=(EXIT,)):
        """Step `at` fails (or, conclusion=cancelled, is cut off by a timeout or a cancel); the post steps still run."""
        names = self.names(name)
        upto = names.index(at)
        steps = [self.passed(name, s) for s in names[:upto]] + [(at, "completed", conclusion)]
        steps += [(s, "completed", "success" if s.startswith("Post ") or s == "Complete job" else "skipped")
                  for s in names[upto + 1:]]
        return self.job(name, "failure" if conclusion == "failure" else "cancelled", steps, messages)

    def cancelled(self, name, message):
        """Cancelled before it got a runner (a newer push, a person)."""
        return self.job(name, "cancelled", [], [message])

    def gate(self, website="success"):
        """check-all: the website step ran (`website`); the gate failed because a shard did, or was skipped after a
        failed website step (it has no if:)."""
        steps = []
        for s in self.summary:
            if s == "Test and build the website":
                steps.append((s, "completed", website))
            elif s == "All shards passed":
                steps.append((s, "completed", "failure" if website == "success" else "skipped"))
            elif s in ("Name the verified tree", "Leave the verified-tree marker"):
                steps.append((s, "completed", "skipped"))
            else:
                steps.append((s, "completed", "success"))
        return self.job("check-all", "failure", steps, [EXIT])

    def run(self, outcome):
        """A whole attempt by keyword: success, failure (a check), cancelled (a person), infra (a shard never got a
        runner), superseded."""
        shards = [f"shard {n}/5" for n in range(1, 6)]
        if outcome == "success":
            return [self.ok(s) for s in shards] + [self.ok("check-all")]
        if outcome == "failure":
            return ([self.failed(shards[0], "Run checks (shard 1 of 5)")] + [self.ok(s) for s in shards[1:]]
                    + [self.gate()])
        if outcome == "infra":
            return [self.not_acquired(shards[0])] + [self.ok(s) for s in shards[1:]] + [self.gate()]
        if outcome in ("cancelled", "superseded"):
            message = PERSON if outcome == "cancelled" else SUPERSEDED
            return [self.cancelled(s, message) for s in shards] + [self.job("check-all", "cancelled", [], [])]
        raise ValueError(outcome)


def conclusion_of(jobs):
    """A run's conclusion from its jobs, like GitHub: green, cancelled when a person or a newer push cancelled it."""
    if all(job["conclusion"] in ("success", "skipped") for job, _ in jobs):
        return "success"
    said = [m for _, messages in jobs for m in messages]
    return "cancelled" if any(PERSON in m or "Canceling since" in m for m in said) else "failure"

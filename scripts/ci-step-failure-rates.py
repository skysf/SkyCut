#!/usr/bin/env python3
"""Read-only CI signal: how often each step of the checks workflow's shard jobs failed, pull requests vs main.

An execution is one job attempt in which the step ran and ended success or failure by the end of the window (so a
past window counts the same later); cancelled and skipped steps don't count. A job that GitHub copies into a re-run attempt (same name, start and end as before) counts once. "Run checks
(shard N of 5)" is counted as one step, "Run checks". A step that fails in more than --threshold percent of its
pull-request executions is flagged with "!": for the playback start benchmark that means recalibrate it
(docs/architecture/playback-start.md). A signal for the coordinator, never a gate; docs/build/build-and-packaging.md "CI".

Usage (from anywhere, with gh logged in; any collaborator's token can read Actions):
  scripts/ci-step-failure-rates.py                         # runs created in the last 24 hours
  scripts/ci-step-failure-rates.py --days 7
  scripts/ci-step-failure-rates.py --since 2026-11-19 --until 2026-11-19T15:10:00Z \\
      --exclude-branch test/play-start-benchmark --exclude-branch fix/playback-start-ci-stability
Exits 1 when the GitHub API can't be read, 2 on bad arguments.
"""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from collections import defaultdict

WORKFLOW = "checks.yml"


def gh_lines(path, jq):
    """Every page of a GET, one jq result per line."""
    done = subprocess.run(["gh", "api", "--paginate", path, "--jq", jq], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"✗ ci-step-failure-rates: gh api {path} failed: {done.stderr.strip()}")
    return [line for line in done.stdout.splitlines() if line.strip()]


def instant(text, end_of_day=False):
    """An ISO date or date-time in UTC."""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        text += "T23:59:59Z" if end_of_day else "T00:00:00Z"
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def kind(run):
    if run["event"] == "pull_request":
        return "pr"
    return "main" if run["head_branch"] == "main" else "other"


def count(repo, runs, until):
    """{step: {kind: [executions, failures]}}"""
    table = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    for run in runs:
        jobs = [json.loads(line) for line in gh_lines(
            f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=all&per_page=100",
            ".jobs[] | {name, run_attempt, started_at, completed_at, steps: [.steps[]? | {name, conclusion, completed_at}]}"
            " | tojson")]
        seen = set()
        for job in sorted(jobs, key=lambda j: j["run_attempt"]):
            copy = (job["name"], job["started_at"], job["completed_at"])
            if job["started_at"] and copy in seen:
                continue
            seen.add(copy)
            if not job["name"].startswith("shard "):
                continue
            for step in job["steps"]:
                if step["conclusion"] not in ("success", "failure") or not step["completed_at"]:
                    continue
                if instant(step["completed_at"]) > until:
                    continue
                name = re.sub(r" \(shard \d+ of \d+\)$", "", step["name"])
                cell = table[name][kind(run)]
                cell[0] += 1
                cell[1] += step["conclusion"] == "failure"
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default="skysf/SkyCut")
    parser.add_argument("--days", type=float, default=1.0, help="window ending now (ignored with --since)")
    parser.add_argument("--since", help="ISO date or date-time, UTC")
    parser.add_argument("--until", help="ISO date or date-time, UTC (default now)")
    parser.add_argument("--exclude-branch", action="append", default=[], help="leave a branch's runs out (repeatable)")
    parser.add_argument("--threshold", type=float, default=5.0, help="flag pull-request failure rates above this %%")
    args = parser.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    until = instant(args.until, end_of_day=True) if args.until else now
    since = instant(args.since) if args.since else until - dt.timedelta(days=args.days)
    if since >= until:
        parser.error("--since must be before --until")
    stamp = "%Y-%m-%dT%H:%M:%SZ"
    lines = gh_lines(
        f"repos/{args.repo}/actions/workflows/{WORKFLOW}/runs?per_page=100"
        f"&created={since.strftime(stamp)}..{until.strftime(stamp)}",
        ".workflow_runs[] | {id, event, head_branch, created_at} | tojson")
    runs = [json.loads(line) for line in lines]
    runs = [r for r in runs if r["head_branch"] not in args.exclude_branch]
    table = count(args.repo, runs, until)

    print(f"{WORKFLOW} shard steps, runs created {since.strftime(stamp)} .. {until.strftime(stamp)}: {len(runs)} runs"
          + (f" (left out: {', '.join(args.exclude_branch)})" if args.exclude_branch else ""))
    print(f"  {'step':<46} {'pull requests':>16} {'main':>14}")
    def cell(pair):
        ran, failed = pair
        return f"{failed}/{ran} ({100.0 * failed / ran:.0f}%)" if ran else "-"
    order = sorted(table, key=lambda s: (-table[s]["pr"][1], s))
    flagged = 0
    for step in order:
        ran, failed = table[step]["pr"]
        flag = "!" if ran and 100.0 * failed / ran > args.threshold else " "
        flagged += flag == "!"
        label = step if len(step) <= 46 else step[:45] + "…"
        print(f"{flag} {label:<46} {cell(table[step]['pr']):>16} {cell(table[step]['main']):>14}")
    print(f"{flagged} step(s) failed in more than {args.threshold:g}% of their pull-request executions"
          + (" (flagged !)" if flagged else ""))


if __name__ == "__main__":
    main()

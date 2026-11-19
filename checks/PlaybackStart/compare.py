"""Fail the GUI check on missing trials, extra preview builds or over-budget playback."""

import argparse
import json
import math
import os
from pathlib import Path
from statistics import median
import sys
from typing import NamedTuple, Optional


TIMINGS = (
    "dispatchMs", "audioMs", "videoMs", "onsetGapMs", "audioAdvanceMs", "videoAdvanceMs",
    "startOffsetMs", "oneSecondOffsetMs", "oneSecondElapsedMs",
)


class TimingFailure(NamedTuple):
    label: str
    scenario: Optional[str]
    metric: str
    value: float
    limit: float

    def __str__(self):
        return f"{self.label}: {self.metric} {self.value:.1f} exceeds {self.limit} ms"


def compare(paths, budgets):
    scenarios = budgets["scenarios"]
    samples = {name: [] for name in scenarios}
    errors = []
    if len(paths) != 5 or len(set(paths)) != 5:
        errors.append("Expected five separate process launches.")
    for path in paths:
        report = json.loads(path.read_text())
        media = report["media"]
        if (media["width"], media["height"], media["keyframeInterval"], media["videoTracks"], media["audioTracks"]) != (
            3840, 2160, 8, 4, 6
        ) or media["primaryBytes"] < 20_000_000:
            errors.append(f"{path.name}: the 4K long-GOP fixture is missing or smaller than expected")
        names = sorted(trial["scenario"] for trial in report["trials"])
        if names != sorted(scenarios):
            errors.append(f"{path.name}: unexpected scenarios {names}")
            continue
        for trial in report["trials"]:
            name = trial["scenario"]
            label = f"{path.name} {name}"
            metrics = trial["metrics"]
            if trial.get("error"):
                errors.append(f"{label}: {trial['error']}")
                continue
            for key in (*TIMINGS, "builds", "itemAttaches", "assetOpens", "videoPrerolls"):
                value = metrics.get(key)
                if type(value) not in (int, float) or not math.isfinite(value):
                    errors.append(f"{label}: missing or invalid {key}")
                    break
            else:
                samples[name].append(metrics)
                check_trial(label, name, metrics, budgets, errors)
    for scenario, trials in samples.items():
        if len(trials) != 5:
            continue
        median_budgets = budgets["medians"]
        limits = median_budgets["common"] | median_budgets["scenarios"].get(scenario, {})
        values = {key: median(abs(trial[key]) for trial in trials) for key in limits}
        check_limits(f"{scenario} median", values, limits, errors)
    return samples, errors


def check_trial(label, scenario, metrics, budgets, errors):
    limits = budgets["common"] | budgets["scenarios"][scenario]
    if set(limits) != set(TIMINGS):
        raise ValueError(f"{scenario} needs a budget for each timing")
    check_limits(label, metrics, limits, errors, scenario)
    for key in ("dispatchMs", "audioMs", "videoMs", "onsetGapMs"):
        if metrics[key] < 0:
            errors.append(f"{label}: {key} happened before Play")
    if metrics["oneSecondElapsedMs"] < 1000:
        errors.append(f"{label}: follow-up frame was less than one second after playback started")
    expected = 1 if scenario == "cold-open" else 0
    for key in ("builds", "itemAttaches"):
        if metrics[key] != expected:
            errors.append(f"{label}: {key} {metrics[key]:g}, expected {expected}")
    if scenario in ("cold-open", "end-replay") and metrics["videoPrerolls"] != 1:
        errors.append(f"{label}: expected one successful native video preroll before playback")
    if scenario == "cold-open" and metrics["assetOpens"] < 3:
        errors.append(f"{label}: expected uncached opens for all three video sources")
    if scenario != "cold-open" and metrics["assetOpens"] != 0:
        errors.append(f"{label}: Play opened a new source asset")


def check_limits(label, metrics, limits, errors, scenario=None):
    for key, limit in limits.items():
        if type(limit) not in (int, float) or not math.isfinite(limit) or limit <= 0:
            raise ValueError(f"{label} has an invalid budget for {key}")
        if abs(metrics[key]) > limit:
            errors.append(TimingFailure(label, scenario, key, metrics[key], limit))


def render(samples, errors, machine, media):
    header = ["Scenario", "Trials", *TIMINGS]
    lines = [
        "## Playback start", "",
        machine,
        f"Fixture: {media['primaryBytes'] / 1e6:.1f} MB, 4K H.264 with an 8 s GOP, 4 video and 6 audio tracks.",
        "", "Times in milliseconds, median / worst. Offsets and advances use absolute values.", "",
        "| " + " | ".join(header) + " |",
        "| " + " | ".join("---" for _ in header) + " |",
    ]
    for name, trials in samples.items():
        cells = [name, str(len(trials))]
        for key in TIMINGS:
            values = [abs(trial[key]) for trial in trials]
            cells.append(f"{median(values):.1f} / {max(values):.1f}" if values else "missing")
        lines.append("| " + " | ".join(cells) + " |")
    if errors:
        lines.extend(["", "Failures", "", *(f"- {error}" for error in errors)])
    return "\n".join(lines) + "\n"


def isolated_virtual_timing_failures(errors):
    # Allow only one affected launch per scenario. Structural, median and large onset failures are final.
    affected = {}
    for error in errors:
        if not isinstance(error, TimingFailure) or error.scenario is None:
            return None
        start_skew_limit = 200 if error.scenario == "cold-open" else 100
        small_start_skew = error.metric == "startOffsetMs" and abs(error.value) <= start_skew_limit
        isolated_rewind = (
            error.scenario == "end-replay" and error.metric in ("audioMs", "videoMs", "onsetGapMs")
            and abs(error.value) <= error.limit + 50
        )
        if not small_start_skew and not isolated_rewind and error.metric not in ("oneSecondOffsetMs", "oneSecondElapsedMs"):
            return None
        affected.setdefault(error.scenario, set()).add(error.label)
    if any(len(trials) > 1 for trials in affected.values()):
        return None
    return set(affected)


def write_report(summary, report):
    print(report, end="")
    summary.write_text(report)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(destination).open("a") as stream:
            stream.write("\n" + report)


def fingerprint(directory):
    return (directory / "machine.txt").read_text().strip().replace("\n", " · ")


def confirm(directory, samples, failures, budgets, machine, media):
    first, first_errors = compare(sorted(directory.glob("trial-[1-5].json")), budgets)
    first_failures = isolated_virtual_timing_failures(first_errors)
    if not first_failures or failures is None or first_failures & failures or fingerprint(directory) != machine:
        print("The second batch did not confirm every scenario with an isolated timing failure.", file=sys.stderr)
        return 1
    confirmed = {name: samples[name] if name in first_failures else trials for name, trials in first.items()}
    report = "## Confirmed playback start\n\nEach scenario has one complete five-launch batch within budget. Both batches are archived.\n\n"
    write_report(directory / "confirmed-summary.md", report + render(confirmed, [], machine, media))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("trials", type=Path, nargs="+")
    parser.add_argument("--confirm", type=Path)
    args = parser.parse_args()
    budgets = json.loads(Path(__file__).with_name("budgets.json").read_text())
    samples, errors = compare(args.trials, budgets)
    machine = fingerprint(args.summary.parent)
    media = json.loads(args.trials[0].read_text())["media"]
    write_report(args.summary, render(samples, errors, machine, media))
    hosted_vm = os.environ.get("CI") == "true" and "hw.model: VirtualMac" in machine
    failures = isolated_virtual_timing_failures(errors) if hosted_vm else None
    if args.confirm:
        return confirm(args.confirm, samples, failures, budgets, machine, media)
    if failures:
        return 2
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())

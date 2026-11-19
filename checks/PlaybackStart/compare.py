"""Fail the GUI check on missing trials, extra preview builds or over-budget playback."""

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
    # Require a clean second batch after an isolated frame-delivery outlier and retain both batches.
    affected = {}
    for error in errors:
        if not isinstance(error, TimingFailure) or error.scenario is None:
            return False
        small_start_skew = (
            error.metric == "startOffsetMs" and error.scenario != "cold-open" and abs(error.value) <= 100
        )
        isolated_rewind = (
            error.scenario == "end-replay" and error.metric in ("audioMs", "videoMs", "onsetGapMs")
            and abs(error.value) <= error.limit + 50
        )
        if not small_start_skew and not isolated_rewind and error.metric not in ("oneSecondOffsetMs", "oneSecondElapsedMs"):
            return False
        affected.setdefault(error.scenario, set()).add(error.label)
    return 0 < len(affected) <= 2 and all(len(trials) == 1 for trials in affected.values())


def main():
    summary, *paths = map(Path, sys.argv[1:])
    if not paths:
        raise ValueError("No playback-start trial reports were provided")
    budgets = json.loads(Path(__file__).with_name("budgets.json").read_text())
    samples, errors = compare(paths, budgets)
    machine = (summary.parent / "machine.txt").read_text().strip().replace("\n", " · ")
    media = json.loads(paths[0].read_text())["media"]
    report = render(samples, errors, machine, media)
    print(report, end="")
    summary.write_text(report)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(destination).open("a") as stream:
            stream.write("\n" + report)
    if os.environ.get("CI") == "true" and "hw.model: VirtualMac" in machine and isolated_virtual_timing_failures(errors):
        return 2
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())

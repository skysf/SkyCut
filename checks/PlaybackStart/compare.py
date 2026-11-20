"""Score every playback launch against the same timeline and timing contract."""

import argparse
import json
import math
import os
from pathlib import Path
from statistics import median
import sys
from typing import NamedTuple


ONSET = (
    "dispatchMs", "audioMs", "videoMs", "onsetGapMs", "audioAdvanceMs", "videoAdvanceMs", "startOffsetMs",
)
FOLLOWUP = ("oneSecondOffsetMs", "oneSecondElapsedMs")
# The picture's first two seconds: the longest time one frame stayed up while playing, and the worst audio-minus-picture
# difference at any displayed frame. A stall after a good start is the reported failure too.
CONTINUITY = ("stallMs", "maxSkewMs")
TIMINGS = ONSET + FOLLOWUP + CONTINUITY
CONTROL = ("displayPeriodMs", "displayGapMs")
COUNTS = ("builds", "itemAttaches", "assetOpens", "videoPrerolls")
# Picture and sound this far apart at the start is the reported failure itself ("the picture takes a while to
# catch up"), whatever the per-launch budget. A run accepts at most one such launch per scenario, and only after
# confirmation. Later drift is held by the one-second budgets: hosted runners stall decoding for a second at times.
GROSS_SKEW_MS = 500
SKEWS = ("onsetGapMs", "startOffsetMs")
# Native prerolls counted after Play: the scenarios that place or prime the picture after Play (the open, a new item,
# the rewind at the end, a click just before Play, a click while playing) prime once. A new item is primed only when
# Play asks: priming every installed composition while editing broke the memory ratchet. A hover runs on its own player
# (since 2026-11-20), so Play during or after one primes nothing: the picture is still placed and primed.
PREROLLS = {"cold-open": 1, "end-replay": 1, "fresh-item": 1, "seek-play": 1, "play-seek": 1, "peek-play": 0,
            "peek-end-play": 0}


class Trial(NamedTuple):
    label: str
    metrics: dict

    def timing(self, metric):
        # A follow-up timeout ranks worse than every measured offset and elapsed time.
        return abs(self.metrics.get(metric, math.inf))


def finite(metrics, key):
    return type(metrics.get(key)) in (int, float) and math.isfinite(metrics[key])


def read_trials(paths, scenarios, expected_count):
    samples = {name: [] for name in scenarios}
    errors = []
    if len(paths) != expected_count or len({path.resolve() for path in paths}) != expected_count:
        errors.append(f"Expected {expected_count} separate process launches")
    fixture = None
    for path in paths:
        report = json.loads(path.read_text())
        media = report["media"]
        if fixture is None:
            fixture = media
        shape = (media["width"], media["height"], media["keyframeInterval"], media["videoTracks"], media["audioTracks"])
        if media != fixture or shape != (3840, 2160, 8, 4, 6) or media["primaryBytes"] < 20_000_000:
            errors.append(f"{path.name}: the 4K long-GOP fixture is missing or changed")
        names = sorted(trial["scenario"] for trial in report["trials"])
        if names != sorted(scenarios):
            errors.append(f"{path.name}: unexpected scenarios {names}")
            continue
        for entry in report["trials"]:
            scenario = entry["scenario"]
            label = f"{path.parent.name}/{path.name} {scenario}"
            if entry.get("error"):
                errors.append(f"{label}: {entry['error']}")
                continue
            trial = Trial(label, entry["metrics"])
            defects = validate_trial(scenario, trial)
            errors.extend(defects)
            if not defects:
                samples[scenario].append(trial)
    return samples, errors, fixture


def validate_trial(scenario, trial):
    metrics = trial.metrics
    keys = (*ONSET, *CONTINUITY, *COUNTS, *CONTROL, "oneSecondTimedOut")
    missing = [key for key in keys if not finite(metrics, key)]
    if missing:
        return [f"{trial.label}: missing or invalid {', '.join(missing)}"]
    timed_out = metrics["oneSecondTimedOut"]
    if timed_out == 0:
        # Subtracting host times leaves a follow-up exactly one second later at 999.9999999999 ms.
        if not all(finite(metrics, key) for key in FOLLOWUP) or metrics["oneSecondElapsedMs"] < 1000 - 1e-6:
            return [f"{trial.label}: invalid one-second follow-up"]
    elif timed_out != 1 or any(key in metrics for key in FOLLOWUP):
        return [f"{trial.label}: inconsistent one-second timeout"]
    if any(metrics[key] < 0 for key in ("dispatchMs", "audioMs", "videoMs", "onsetGapMs")):
        return [f"{trial.label}: playback timing preceded Play"]
    if any(metrics[key] <= 0 for key in CONTROL):
        return [f"{trial.label}: display cadence control did not run"]

    cold = scenario == "cold-open"
    expected = {"builds": int(cold), "itemAttaches": int(cold), "assetOpens": 3 if cold else 0}
    if scenario in PREROLLS:
        expected["videoPrerolls"] = PREROLLS[scenario]
    return [f"{trial.label}: {key} {metrics[key]:g}, expected {count}"
            for key, count in expected.items() if metrics[key] != count]


def stalled(trial):
    # A missed follow-up ranks as infinitely late, so it is a stall too.
    return trial.metrics["oneSecondTimedOut"] == 1 or any(trial.timing(metric) >= GROSS_SKEW_MS for metric in SKEWS)


def evaluate(samples, budgets, confirmed=False):
    errors, outliers = [], []
    for name, trials in samples.items():
        single = budgets["common"] | budgets["scenarios"][name]
        typical = budgets["medians"]["common"] | budgets["medians"]["scenarios"].get(name, {})
        if set(single) != set(TIMINGS) or set(typical) != set(TIMINGS) - {"oneSecondElapsedMs"}:
            raise ValueError(f"{name} needs the full set of playback timing limits")
        if not all(finite(limits, key) and limits[key] > 0 for limits in (single, typical) for key in limits):
            raise ValueError(f"{name} has an invalid playback budget")
        if any(typical[key] > single[key] for key in typical):
            raise ValueError(f"{name} has a median budget above its per-launch budget")
        # The worst skew includes the first frame, so it can never be below the start skew.
        if any(limits["maxSkewMs"] < limits["startOffsetMs"] for limits in (single, typical)):
            raise ValueError(f"{name} has a worst-skew budget below its start-skew budget")
        valid = 0
        stalls = 0
        for trial in trials:
            stalls += stalled(trial)
            exceeded = [f"{metric} {trial.timing(metric):.1f} > {limit:g} ms"
                        for metric, limit in single.items() if metric in trial.metrics and trial.timing(metric) > limit]
            if trial.metrics["oneSecondTimedOut"] == 1:
                exceeded.append("one-second follow-up timed out after both streams started")
            if exceeded:
                outliers.append(f"{trial.label}: {', '.join(exceeded)}")
            else:
                valid += 1
        if valid * 2 < len(trials):
            errors.append(f"{name}: {valid}/{len(trials)} whole launches within the per-launch budgets; at least half are required")
        if stalls > int(confirmed):
            errors.append(f"{name}: {stalls} of {len(trials)} launches had picture and sound {GROSS_SKEW_MS} ms or more apart "
                          "or missed the one-second follow-up")
        for metric, limit in typical.items():
            observed = median(trial.timing(metric) for trial in trials)
            if observed > limit:
                errors.append(f"{name} median: {metric} {observed:.1f} exceeds {limit:g} ms")
    return errors, outliers


def strict(samples, profile):
    """Off the hosted runner every launch of every scenario keeps the picture in step with the sound, except the ones
    listed under `skip` (none since the start after the idle stop was fixed: docs/architecture/playback-start.md)."""
    failures = []
    for name, trials in samples.items():
        if name in profile.get("skip", []):
            continue
        limits = profile["common"]
        if set(limits) - set(TIMINGS) or not all(finite(limits, key) and limits[key] > 0 for key in limits):
            raise ValueError("The strict playback limits must be positive timings")
        for trial in trials:
            over = [f"{metric} {trial.timing(metric):.1f} > {limit:g} ms"
                    for metric, limit in limits.items() if trial.timing(metric) > limit]
            if over:
                failures.append(f"{trial.label}: picture not in step with the sound: {', '.join(over)}")
    return failures


def warmup_note(path):
    """The unscored first launch in one line, so a stall there stays visible."""
    try:
        report = json.loads(path.read_text())
        cells = [f"{entry['scenario']} " + ("error" if entry.get("error") else
                                            f"skew {abs(entry['metrics']['startOffsetMs']):.0f}")
                 for entry in report["trials"]]
    except (OSError, ValueError, KeyError, TypeError):
        return "Warm-up launch (not scored): no result, see warmup/trial-1.log."
    return "Warm-up launch (not scored), start skew in ms: " + ", ".join(cells) + "."


def render(samples, errors, outliers, machine, media, warmup=None):
    header = ["Scenario", "Trials", *TIMINGS, "displayGapMs"]
    lines = ["## Playback start", "", machine,
             f"Fixture: {media['primaryBytes'] / 1e6:.1f} MB, 4K H.264 with an 8 s GOP, 4 video and 6 audio tracks.",
             "", "Values in milliseconds, median / worst. Offsets and advances use absolute values.", ""]
    lines.extend(["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"])
    for name, trials in samples.items():
        cells = [name, str(len(trials))]
        for metric in (*TIMINGS, "displayGapMs"):
            values = [trial.timing(metric) for trial in trials]
            cells.append(f"{format_timing(median(values))} / {format_timing(max(values))}" if values else "missing")
        lines.append("| " + " | ".join(cells) + " |")
    if warmup is not None:
        lines.extend(["", warmup_note(warmup)])
    if outliers:
        lines.extend(["", "Individual outliers and timeouts", "", *(f"- {outlier}" for outlier in outliers)])
    if errors:
        lines.extend(["", "Failures", "", *(f"- {error}" for error in errors)])
    return "\n".join(lines) + "\n"


def format_timing(value):
    return f"{value:.1f}" if math.isfinite(value) else "timeout"


def write_report(summary, report):
    print(report, end="")
    summary.write_text(report)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(destination).open("a") as stream:
            stream.write("\n" + report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("trials", type=Path, nargs="+")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--warmup", type=Path, help="the unscored first launch, reported only")
    args = parser.parse_args()
    budgets = json.loads(Path(__file__).with_name("budgets.json").read_text())
    machine = (args.summary.parent / "machine.txt").read_text().strip().replace("\n", " · ")
    hosted = os.environ.get("CI") == "true" and "hw.model: VirtualMac" in machine
    samples, errors, media = read_trials(args.trials, budgets["scenarios"], 8 if args.confirm else 5)
    if args.confirm and not hosted:
        errors.append("Playback confirmation requires the hosted virtual Mac")
    if errors:
        write_report(args.summary, render(samples, errors, [], machine, media, args.warmup))
        return 1
    failures, outliers = evaluate(samples, budgets, args.confirm)
    if not hosted:
        failures += strict(samples, budgets["strict"])
    write_report(args.summary, render(samples, failures, outliers, machine, media, args.warmup))
    if failures and hosted and not args.confirm:
        return 2
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())

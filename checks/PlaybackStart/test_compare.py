"""Pin the playback gate's verdict on isolated stalls, bounded confirmation and broken startup."""

import json
from pathlib import Path
import unittest

from compare import FOLLOWUP, TIMINGS, Trial, evaluate, validate_trial


BUDGETS = json.loads(Path(__file__).with_name("budgets.json").read_text())


def trial(name, **changes):
    cold = name == "cold-open"
    metrics = dict.fromkeys(TIMINGS, 0)
    metrics.update(audioMs=50, videoMs=65, oneSecondElapsedMs=1017,
                   builds=int(cold), itemAttaches=int(cold), assetOpens=3 if cold else 0,
                   videoPrerolls=int(cold or name == "end-replay"),
                   displayPeriodMs=16.67, displayGapMs=18, oneSecondTimedOut=0)
    metrics.update(changes)
    return Trial(name, metrics)


def batch(launches):
    return {name: [trial(name) for _ in range(launches)] for name in BUDGETS["scenarios"]}


def timeout(name):
    result = trial(name, oneSecondTimedOut=1)
    for field in FOLLOWUP:
        del result.metrics[field]
    return result


class PlaybackGateTests(unittest.TestCase):
    def test_two_isolated_late_followups_keep_their_raw_errors(self):
        samples = batch(5)
        cut = samples["cut"]
        cut[0] = trial("cut", oneSecondOffsetMs=1364.8, oneSecondElapsedMs=1980.2)
        cut[1] = trial("cut", oneSecondOffsetMs=229, oneSecondElapsedMs=1305)
        errors, outliers, _ = evaluate(samples, BUDGETS)
        self.assertEqual(errors, [])
        self.assertEqual(len(outliers), 2)
        self.assertIn("1364.8", outliers[0])
        cut[2] = trial("cut", oneSecondOffsetMs=200)
        errors, _, _ = evaluate(samples, BUDGETS)
        self.assertTrue(any("cut: 2/5" in error for error in errors))

    def test_confirmed_samples_cannot_replace_bad_cold_starts(self):
        samples = batch(8)
        for index in range(5):
            samples["cold-open"][index] = trial("cold-open", startOffsetMs=617)
        errors, _, _ = evaluate(samples, BUDGETS, confirmed=True)
        self.assertTrue(any("cold-open: 3/8" in error for error in errors))
        self.assertTrue(any("cold-open median: startOffsetMs" in error for error in errors))

    def test_even_confirmation_keeps_the_medians_and_whole_launch_count(self):
        samples = batch(8)
        replay = samples["end-replay"]
        replay[0] = replay[1] = trial("end-replay", videoMs=321)
        replay[2] = replay[3] = trial("end-replay", startOffsetMs=65)
        errors, outliers, _ = evaluate(samples, BUDGETS, confirmed=True)
        self.assertEqual(errors, [])
        self.assertEqual(len(outliers), 4)
        replay[4] = trial("end-replay", audioMs=350)
        self.assertTrue(any("end-replay: 3/8" in error for error in evaluate(samples, BUDGETS, confirmed=True)[0]))

    def test_followup_timeout_requires_confirmation_and_counts_against_it(self):
        first = batch(5)
        first["cold-open"][0] = timeout("cold-open")
        self.assertEqual(validate_trial("cold-open", first["cold-open"][0]), [])
        errors, _, _ = evaluate(first, BUDGETS)
        self.assertTrue(any("1 follow-up timeout" in error for error in errors))
        second = batch(3)
        combined = {name: trials + second[name] for name, trials in first.items()}
        errors, outliers, _ = evaluate(combined, BUDGETS, confirmed=True)
        self.assertEqual(errors, [])
        self.assertIn("timed out", outliers[0])
        combined["cold-open"][-1] = timeout("cold-open")
        self.assertTrue(evaluate(combined, BUDGETS, confirmed=True)[0])

    def test_confirmation_margin_uses_the_same_runs_display_control(self):
        samples = batch(8)
        samples["end-replay"] = [trial("end-replay", audioMs=194, videoMs=265)] * 8
        errors, _, interval = evaluate(samples, BUDGETS, confirmed=True)
        self.assertEqual(errors, [])
        self.assertEqual(interval, 16.67)
        samples["warm-start"] = [trial("warm-start", displayPeriodMs=10)] * 8
        self.assertTrue(evaluate(samples, BUDGETS, confirmed=True)[0])
        samples["warm-start"] = [trial("warm-start", audioMs=139)] * 8
        self.assertTrue(evaluate(samples, BUDGETS, confirmed=True)[0])
        samples["cut"] = [trial("cut", oneSecondOffsetMs=36)] * 8
        self.assertTrue(any("cut median" in error for error in evaluate(samples, BUDGETS, confirmed=True)[0]))

    def test_missing_onset_and_extra_cold_work_are_hard_errors(self):
        missing = trial("cold-open")
        del missing.metrics["videoMs"]
        self.assertTrue(validate_trial("cold-open", missing))
        self.assertTrue(validate_trial("cold-open", trial("cold-open", builds=2)))
        self.assertTrue(validate_trial("cold-open", trial("cold-open", displayGapMs=0)))


if __name__ == "__main__":
    unittest.main()

"""Pin the playback gate's verdict on isolated stalls, bounded confirmation, broken startup and the recorded bug."""

import json
from pathlib import Path
import unittest

from compare import FOLLOWUP, PREROLLS, TIMINGS, Trial, evaluate, strict, validate_trial


BUDGETS = json.loads(Path(__file__).with_name("budgets.json").read_text())


def trial(name, **changes):
    cold = name == "cold-open"
    metrics = dict.fromkeys(TIMINGS, 0)
    metrics.update(audioMs=50, videoMs=65, oneSecondElapsedMs=1017, stallMs=33.3, maxSkewMs=12,
                   builds=int(cold), itemAttaches=int(cold), assetOpens=3 if cold else 0,
                   videoPrerolls=PREROLLS.get(name, 0),
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


# The hosted runner before the #502 fix (run 44446600269): sound started first and the picture caught up later.
RECORDED_BUG = {
    "cold-open": dict(startOffsetMs=[617, 283, 237, 212, 196], onsetGapMs=[750, 450, 260, 368, 219],
                      audioMs=[1764, 955, 830, 849, 553], videoMs=[2514, 1404, 1090, 1216, 772]),
    "end-replay": dict(startOffsetMs=[235, 126, 93, 70, 82], onsetGapMs=[401, 215, 93, 104, 104],
                       audioMs=[54, 74, 50, 26, 39], videoMs=[455, 290, 143, 130, 144]),
}


# The slowest healthy hosted run of 2026-11-19 (run 44557659527, the main branch's code): five launches and three
# confirmation launches of the cold open. Its first five fail; all eight must pass.
SLOW_HOSTED_COLD_OPEN = dict(
    onsetGapMs=[140.0, 101.9, 230.5, 249.1, 251.6, 124.0, 161.3, 187.4],
    startOffsetMs=[106.7, 79.2, 207.8, 226.4, 218.3, 101.3, 128.0, 154.1],
    oneSecondOffsetMs=[6.7, 4.1, 107.8, 59.8, 68.3, 15.4, 78.0, 12.6],
)


# The M1 before the 2026-11-19 fix: a resume and a Play while hovering sent the sound first and re-seeked the 4K
# long-GOP picture, which stayed frozen for 0.6-0.9 s (docs/bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md).
RECORDED_FREEZE = {
    "resume": dict(audioMs=[27.5, 34.4, 28.7], videoMs=[826.8, 921.1, 830.4], onsetGapMs=[799.3, 886.7, 801.7]),
    "peek-play": dict(audioMs=[35.7, 37.6, 31.7], videoMs=[635.4, 655.0, 623.6], onsetGapMs=[599.7, 617.4, 591.9]),
}


# The M1 before the 2026-11-20 fix, eight starts after a 20 s idle stop: the picture started ahead of the sound and the
# drift correction re-seeked it, or the sound lost its start (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
RECORDED_IDLE_START = [
    dict(startOffsetMs=-96.8, stallMs=133.3, maxSkewMs=96.8, onsetGapMs=75.1),
    dict(startOffsetMs=-18.6, stallMs=33.3, maxSkewMs=18.6, onsetGapMs=3.1),
    dict(startOffsetMs=-22.9, stallMs=33.3, maxSkewMs=22.8, onsetGapMs=1.2),
    dict(startOffsetMs=-78.6, stallMs=116.7, maxSkewMs=78.6, onsetGapMs=56.9),
    dict(startOffsetMs=-8.5, stallMs=33.3, maxSkewMs=8.5, onsetGapMs=13.2),
    dict(startOffsetMs=-19.1, stallMs=33.3, maxSkewMs=19.1, onsetGapMs=94.8),
    dict(startOffsetMs=-41.5, stallMs=66.7, maxSkewMs=41.5, onsetGapMs=19.8),
    dict(startOffsetMs=-12.8, stallMs=33.3, maxSkewMs=12.8, onsetGapMs=26.0),
]


# The M1 before the 2026-11-20 fix: a click far ahead while playing (11 s to 18 s, three seconds into an 8 s 4K GOP) sent
# the sound there at once and re-seeked the picture under it, frozen for about a second.
RECORDED_CLICK_WHILE_PLAYING = dict(
    audioMs=[33.8, 32.4, 31.8, 31.3, 34.1],
    videoMs=[1036.8, 1046.2, 1039.5, 1028.0, 1025.0],
    onsetGapMs=[1003.0, 1013.7, 1007.8, 996.8, 990.8],
    startOffsetMs=[15.9, -6.7, -12.6, 9.7, 3.7],
)


# The M1 before the 2026-11-20 hover player (gate run of PR #536's bench on main's code): Play while hovering waited for
# the playhead's 4K mid-GOP frame to be decoded again, in step but 0.6 s late, after re-priming the picture.
RECORDED_HOVER_WAIT = dict(
    audioMs=[584.2, 593.4, 591.1, 590.7, 585.1],
    videoMs=[606.3, 616.7, 605.7, 615.8, 605.6],
    onsetGapMs=[22.1, 23.3, 14.6, 25.1, 20.6],
    startOffsetMs=[-11.2, -10.0, -18.7, -8.2, -12.7],
    maxSkewMs=[11.2, 10.0, 18.7, 8.2, 12.7],
)


class PlaybackGateTests(unittest.TestCase):
    def test_recorded_m1_freezes_fail_hosted_and_local_scoring(self):
        samples = batch(5)
        for name, columns in RECORDED_FREEZE.items():
            for index in range(3):
                samples[name][index] = trial(name, **{metric: values[index] for metric, values in columns.items()})
        errors, _ = evaluate(samples, BUDGETS)
        self.assertTrue(any("resume: 3 of 5 launches had picture and sound 500 ms" in error for error in errors))
        self.assertTrue(any("peek-play median: onsetGapMs" in error for error in errors))
        self.assertEqual(len(strict(samples, BUDGETS["strict"])), 6)

    def test_play_after_a_hover_starts_without_waiting_for_a_decode(self):
        # Since 2026-11-20 a hover runs on its own player: Play during or right after it primes nothing and starts like a
        # placed playhead. Before, it waited for the playhead's frame, in step but 0.6 s late: in budget then, red now.
        samples = batch(5)
        for name in ("peek-play", "peek-end-play"):
            samples[name] = [trial(name, **{metric: values[index] for metric, values in RECORDED_HOVER_WAIT.items()},
                                   videoPrerolls=1) for index in range(5)]
        errors, _ = evaluate(samples, BUDGETS)
        for name in ("peek-play", "peek-end-play"):
            self.assertTrue(any(f"{name} median: audioMs" in error for error in errors))
            self.assertTrue(any(f"{name}: 0/5 whole launches" in error for error in errors))
            self.assertTrue(validate_trial(name, samples[name][0]))
            self.assertEqual(validate_trial(name, trial(name)), [])
        self.assertEqual(strict(samples, BUDGETS["strict"]), [])

    def test_the_slowest_healthy_hosted_cold_open_passes_after_confirmation(self):
        launches = [trial("cold-open", **{metric: values[index] for metric, values in SLOW_HOSTED_COLD_OPEN.items()},
                          maxSkewMs=SLOW_HOSTED_COLD_OPEN["startOffsetMs"][index]) for index in range(8)]
        first = batch(5)
        first["cold-open"] = launches[:5]
        self.assertTrue(any("cold-open median: onsetGapMs" in error for error in evaluate(first, BUDGETS)[0]))
        confirmed = batch(8)
        confirmed["cold-open"] = launches
        self.assertEqual(evaluate(confirmed, BUDGETS, confirmed=True)[0], [])

    def test_a_new_item_has_room_for_its_preroll_but_not_for_skew(self):
        # Play primes a new item: 101 / 141 ms median to sound and picture hosted, 120 / 137 ms on the M1, in step.
        samples = batch(5)
        samples["fresh-item"] = [trial("fresh-item", audioMs=160, videoMs=175)] * 5
        self.assertEqual(evaluate(samples, BUDGETS)[0], [])
        # Primed at a quarter rate while paused, the hosted runner started it 52-60 ms behind (median): too far.
        samples["fresh-item"] = [trial("fresh-item", startOffsetMs=55, maxSkewMs=55)] * 5
        self.assertTrue(any("fresh-item median: startOffsetMs" in error for error in evaluate(samples, BUDGETS)[0]))

    def test_play_primes_a_new_item_once(self):
        self.assertEqual(validate_trial("fresh-item", trial("fresh-item")), [])
        self.assertTrue(validate_trial("fresh-item", trial("fresh-item", videoPrerolls=0)))
        self.assertTrue(validate_trial("fresh-item", trial("fresh-item", videoPrerolls=2)))

    def test_a_stall_after_a_good_start_fails(self):
        samples = batch(5)
        samples["cut"][0] = trial("cut", stallMs=700, maxSkewMs=690)
        errors, outliers = evaluate(samples, BUDGETS)
        self.assertEqual(errors, [])
        self.assertIn("stallMs 700.0 > 300 ms", outliers[0])
        for index in (1, 2):
            samples["cut"][index] = trial("cut", stallMs=700)
        errors, _ = evaluate(samples, BUDGETS)
        self.assertTrue(any("cut: 2/5" in error for error in errors))
        self.assertTrue(any("cut median: stallMs" in error for error in errors))

    def test_this_mac_fails_any_stall_or_skew_the_hosted_budgets_tolerate(self):
        samples = batch(5)
        samples["middle"][0] = trial("middle", stallMs=140)
        samples["warm-start"][2] = trial("warm-start", onsetGapMs=80)
        self.assertEqual(evaluate(samples, BUDGETS)[0], [])
        failures = strict(samples, BUDGETS["strict"])
        self.assertEqual(len(failures), 2)
        self.assertIn("stallMs 140.0 > 100 ms", failures[0] + failures[1])
        self.assertEqual(strict(batch(5), BUDGETS["strict"]), [])
        # Since 2026-11-20 the first sound is at the playhead itself; a cold open whose first advancing picture is the
        # second frame is in step at an onset gap of up to two frames (M1: 47-64 ms, start skew -2 to -19 ms).
        samples = batch(5)
        samples["cold-open"] = [trial("cold-open", onsetGapMs=64.2, startOffsetMs=-2.4, maxSkewMs=12)] * 5
        self.assertEqual(strict(samples, BUDGETS["strict"]), [])

    def test_recorded_idle_start_and_click_while_playing_fail_on_this_mac(self):
        # Before 2026-11-20 the start after the idle stop ran the picture ahead and its drift correction re-seeked it,
        # and a click while playing sent the sound at once over a picture frozen for the decode
        # (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
        samples = batch(5)
        samples["idle-wake"] = [trial("idle-wake", **launch) for launch in RECORDED_IDLE_START]
        failures = strict(samples, BUDGETS["strict"])
        self.assertEqual(len(failures), 3)
        self.assertTrue(all("idle-wake" in failure for failure in failures))
        samples = batch(5)
        for index in range(5):
            samples["play-seek"][index] = trial("play-seek", **{metric: values[index] for metric, values in RECORDED_CLICK_WHILE_PLAYING.items()})
        errors, _ = evaluate(samples, BUDGETS)
        self.assertTrue(any("play-seek: 5 of 5 launches had picture and sound 500 ms" in error for error in errors))
        self.assertEqual(len(strict(samples, BUDGETS["strict"])), 5)
        # The re-seek under the running sound also skipped the placement of the picture.
        self.assertTrue(validate_trial("play-seek", trial("play-seek", videoPrerolls=0)))

    def test_two_isolated_late_followups_keep_their_raw_errors(self):
        samples = batch(5)
        cut = samples["cut"]
        cut[0] = trial("cut", oneSecondOffsetMs=1364.8, oneSecondElapsedMs=1980.2)
        cut[1] = trial("cut", oneSecondOffsetMs=229, oneSecondElapsedMs=1305)
        errors, outliers = evaluate(samples, BUDGETS)
        self.assertEqual(errors, [])
        self.assertEqual(len(outliers), 2)
        self.assertIn("1364.8", outliers[0])
        cut[2] = trial("cut", oneSecondOffsetMs=200)
        errors, _ = evaluate(samples, BUDGETS)
        self.assertTrue(any("cut: 2/5" in error for error in errors))

    def test_confirmed_samples_cannot_replace_bad_cold_starts(self):
        samples = batch(8)
        for index in range(5):
            samples["cold-open"][index] = trial("cold-open", startOffsetMs=617)
        errors, _ = evaluate(samples, BUDGETS, confirmed=True)
        self.assertTrue(any("cold-open: 3/8" in error for error in errors))
        self.assertTrue(any("cold-open median: startOffsetMs" in error for error in errors))
        self.assertTrue(any("cold-open: 5 of 8 launches" in error for error in errors))

    def test_even_confirmation_keeps_the_medians_and_whole_launch_count(self):
        samples = batch(8)
        replay = samples["end-replay"]
        replay[0] = replay[1] = trial("end-replay", videoMs=420)
        replay[2] = replay[3] = trial("end-replay", startOffsetMs=65)
        errors, outliers = evaluate(samples, BUDGETS, confirmed=True)
        self.assertEqual(errors, [])
        self.assertEqual(len(outliers), 4)
        replay[4] = trial("end-replay", audioMs=350)
        self.assertTrue(any("end-replay: 3/8" in error for error in evaluate(samples, BUDGETS, confirmed=True)[0]))

    def test_followup_timeout_requires_confirmation_and_counts_against_it(self):
        first = batch(5)
        first["cold-open"][0] = timeout("cold-open")
        self.assertEqual(validate_trial("cold-open", first["cold-open"][0]), [])
        errors, _ = evaluate(first, BUDGETS)
        self.assertTrue(any("cold-open: 1 of 5 launches" in error for error in errors))
        second = batch(3)
        combined = {name: trials + second[name] for name, trials in first.items()}
        errors, outliers = evaluate(combined, BUDGETS, confirmed=True)
        self.assertEqual(errors, [])
        self.assertIn("timed out", outliers[0])
        combined["cold-open"][-1] = timeout("cold-open")
        self.assertTrue(evaluate(combined, BUDGETS, confirmed=True)[0])

    def test_one_gross_start_skew_needs_confirmation_and_two_fail(self):
        # A picture a second behind its sound is the reported failure, even in one launch.
        first = batch(5)
        first["cut"][0] = trial("cut", startOffsetMs=1100, onsetGapMs=1100)
        errors, _ = evaluate(first, BUDGETS)
        self.assertTrue(any("cut: 1 of 5 launches" in error for error in errors))
        combined = {name: trials + batch(3)[name] for name, trials in first.items()}
        self.assertEqual(evaluate(combined, BUDGETS, confirmed=True)[0], [])
        combined["cut"][6] = trial("cut", onsetGapMs=520)
        self.assertTrue(any("cut: 2 of 8 launches" in error for error in evaluate(combined, BUDGETS, confirmed=True)[0]))

    def test_confirmation_adds_no_margin_to_the_medians(self):
        samples = batch(8)
        samples["end-replay"] = [trial("end-replay", audioMs=249, videoMs=329)] * 8
        self.assertEqual(evaluate(samples, BUDGETS, confirmed=True)[0], [])
        samples["end-replay"] = [trial("end-replay", audioMs=251)] * 8
        self.assertTrue(any("end-replay median: audioMs" in error for error in evaluate(samples, BUDGETS, confirmed=True)[0]))
        samples = batch(8)
        samples["warm-start"] = [trial("warm-start", audioMs=201)] * 8
        self.assertTrue(evaluate(samples, BUDGETS, confirmed=True)[0])
        samples = batch(8)
        samples["cut"] = [trial("cut", oneSecondOffsetMs=36)] * 8
        self.assertTrue(any("cut median" in error for error in evaluate(samples, BUDGETS, confirmed=True)[0]))

    def test_recorded_bug_and_a_delayed_play_stay_red_after_healthy_confirmation(self):
        # Even if every confirmation launch were healthy, the recorded failure must not pass.
        bug = batch(5)
        for name, columns in RECORDED_BUG.items():
            bug[name] = [trial(name, **{metric: values[index] for metric, values in columns.items()}) for index in range(5)]
        self.assertTrue(evaluate(bug, BUDGETS)[0])
        healthy = batch(3)
        errors, _ = evaluate({name: trials + healthy[name] for name, trials in bug.items()}, BUDGETS, confirmed=True)
        self.assertTrue(any("cold-open median: onsetGapMs" in error for error in errors))
        self.assertTrue(any("end-replay median: startOffsetMs" in error for error in errors))
        # 350 ms injected at the production Play entry delays both streams in every positioned start.
        delayed = {name: [trial(name, audioMs=50 + 350, videoMs=65 + 350) for _ in range(8)] for name in BUDGETS["scenarios"]}
        errors, _ = evaluate(delayed, BUDGETS, confirmed=True)
        self.assertTrue(any("warm-start median: audioMs" in error for error in errors))
        self.assertTrue(any("middle median: videoMs" in error for error in errors))

    def test_followup_exactly_one_second_later_survives_host_time_rounding(self):
        self.assertEqual(validate_trial("idle-wake", trial("idle-wake", oneSecondElapsedMs=999.9999999999432)), [])
        self.assertTrue(validate_trial("idle-wake", trial("idle-wake", oneSecondElapsedMs=983.3)))

    def test_missing_onset_and_extra_cold_work_are_hard_errors(self):
        missing = trial("cold-open")
        del missing.metrics["videoMs"]
        self.assertTrue(validate_trial("cold-open", missing))
        self.assertTrue(validate_trial("cold-open", trial("cold-open", builds=2)))
        self.assertTrue(validate_trial("cold-open", trial("cold-open", displayGapMs=0)))

    def test_a_median_budget_above_its_per_launch_budget_is_rejected(self):
        budgets = json.loads(json.dumps(BUDGETS))
        budgets["medians"]["scenarios"]["end-replay"]["startOffsetMs"] = 61
        with self.assertRaises(ValueError):
            evaluate(batch(5), budgets)

    def test_a_worst_skew_budget_below_the_start_skew_budget_is_rejected(self):
        budgets = json.loads(json.dumps(BUDGETS))
        budgets["medians"]["scenarios"]["near-end"]["maxSkewMs"] = 40
        with self.assertRaises(ValueError):
            evaluate(batch(5), budgets)


if __name__ == "__main__":
    unittest.main()

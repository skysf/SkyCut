"""Exercise E2E job deadlines, live suite output, the home boundary, and candidate updates without launching the App."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/gui-smoke/e2e"))
import launch
import reference_edits as edits
import reference_output as output
import run


class RenderJob:
    def __init__(self):
        self.seconds = 0

    def call_with_content(self, tool, arguments, timeout):
        assert tool == "get_job" and arguments["wait_seconds"] <= timeout
        self.seconds += arguments["wait_seconds"]
        status = "done" if self.seconds >= 100 else "running"
        return {"job_id": arguments["job_id"], "status": status, "phase": "rendering"}, False, []

    def call(self, tool, timeout):
        assert tool == "get_status"
        return {"projects": [{"id": "p2", "shown_in": "background (no window)", "view": "background"}]}, False


class HarnessChecks(unittest.TestCase):
    def test_render_can_finish_after_the_old_deadline(self):
        client = RenderJob()
        with patch.object(run.time, "monotonic", lambda: client.seconds), contextlib.redirect_stdout(io.StringIO()):
            job = run.Session(client).job({"job_id": "motion-1"})
        self.assertEqual(job["status"], "done")
        self.assertEqual(client.seconds, 100)

    def test_deadline_keeps_the_last_phase_and_window_state(self):
        client = RenderJob()
        session = run.Session(client)
        with patch.object(run.time, "monotonic", lambda: client.seconds), patch.object(run, "JOB_TIMEOUT", 62), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as log:
            with self.assertRaisesRegex(TimeoutError, "motion-1.*62s"):
                session.job({"job_id": "motion-1"})
            session.diagnose()
        self.assertEqual(client.seconds, 62)
        self.assertIn("'phase': 'rendering'", log.getvalue())
        self.assertIn("background (no window)", log.getvalue())

    def test_suite_output_streams_while_the_suite_runs(self):
        # A cancelled CI job never reaches the end of supervise(), so only lines already relayed reach its log.
        with tempfile.TemporaryDirectory() as root:
            release = Path(root) / "release"
            suite = ("import pathlib, time\nprint('Waiting for MCP job motion-1', flush=True)\n"
                     f"while not pathlib.Path({str(release)!r}).exists(): time.sleep(0.05)\n")
            captured = io.TextIOWrapper(io.BytesIO(), write_through=True)
            with contextlib.redirect_stdout(captured):
                worker = threading.Thread(target=launch.supervise, args=([sys.executable, "-c", suite], {}, Path(root)),
                                          daemon=True)
                worker.start()
                deadline = time.monotonic() + 10
                while b"motion-1" not in captured.buffer.getvalue() and time.monotonic() < deadline:
                    time.sleep(0.05)
                live = captured.buffer.getvalue()
                release.touch()
                worker.join(timeout=10)
            self.assertIn(b"Waiting for MCP job motion-1", live, "Suite output appeared only after the suite ended")
            self.assertFalse(worker.is_alive())

    def test_reference_waits_for_source_scan_before_placement(self):
        class Session:
            ready = False

            def edit(self, tool, **arguments):
                if tool == "set_canvas":
                    return {}
                if tool == "look":
                    assert arguments == {"file": "amber.mp4", "shots": True, "image": False}
                    return {"job_id": "look-1"}
                assert tool == "add_clips"
                reply = {"added": [{"track": track, "id": f"c{index}"} for index, track in
                                   enumerate(("V1", "V1", "V1", "V2", "V2"), 1)]}
                if self.ready:
                    reply["source_cuts"] = [{"clip": "c1", "source_frame": 58, "frames_after_cut": 2,
                                             "suggested_source_out": 2.417}]
                else:
                    reply["source_cuts_unchecked"] = {"clips": ["c1"]}
                return reply

            def job(self, started):
                if started["job_id"] == "look-1":
                    return {"result": {"job_id": "shots-2"}}
                assert started["job_id"] == "shots-2"
                self.ready = True
                return {"shots": 2}

        self.assertEqual(edits.add_picture(Session()), "c1")

    def test_candidate_keeps_baseline_and_emits_diff(self):
        with tempfile.TemporaryDirectory() as root:
            baseline = Path(root) / "reference_golden.json"
            baseline.write_text(output.encode({"measurement": -12}))
            expected = baseline.read_bytes()
            with patch.object(output, "GOLDEN", baseline), patch.object(output.tempfile, "mkdtemp", return_value=root), \
                    contextlib.redirect_stdout(io.StringIO()):
                paths = output.record_or_compare({"measurement": -2}, update=True)
            self.assertEqual(baseline.read_bytes(), expected)
            candidate, diff = paths
            self.assertEqual(json.loads(candidate.read_text()), {"measurement": -2})
            self.assertIn('-  "measurement": -12', diff.read_text())
            self.assertIn('+  "measurement": -2', diff.read_text())

    def test_delivery_oracle_refuses_a_missing_cut(self):
        source = [-16, -13, -20]
        output.require_voice_band_cut([-13, -22, -17], source)
        with self.assertRaisesRegex(AssertionError, "960 Hz voice cut"):
            output.require_voice_band_cut([-13, -10, -17], source)

    def test_real_home_boundary_denies_writes_and_reports_daemon_artifacts(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root).resolve()
            target = home / "outside"
            result = subprocess.run(launch.sandbox_command(home, ["/usr/bin/touch", str(target)]),
                                    env={"LC_ALL": "C"}, text=True, capture_output=True, timeout=10)
            self.assertNotIn("sandbox_apply", result.stderr)
            self.assertIn("Operation not permitted", result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())
            profile = home / "Library/Preferences/com.srtflow.e2egui123.plist"
            profile.parent.mkdir(parents=True)
            profile.touch()
            with self.assertRaisesRegex(RuntimeError, "real home.*e2egui123"):
                launch.assert_no_home_artifacts(home, "com.srtflow.e2egui123")


if __name__ == "__main__":
    unittest.main()

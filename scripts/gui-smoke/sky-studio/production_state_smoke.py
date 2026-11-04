"""Executable background MCP state acceptance, invoked only after root launches the fake App.

The process keeps its helper/session alive while waiting for actual visual observations.
It never starts/stops an App/server, edits a project file, submits generation, or listens
subjectively. Existing official.py separately owns financial receipt recovery cases.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import traceback

sys.dont_write_bytecode = True


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--support-dir", type=Path, default=Path(__file__).parent,
                        help="Directory containing existing official_client.py (same directory after integration)")
    parser.add_argument("--native-dir", type=Path, default=Path(__file__).parent,
                        help="Directory containing native_anchor_capture.py and mcp_source_frame_smoke.py")
    parser.add_argument("--skip-native-boundaries", action="store_true",
                        help="Explicitly skip the six native boundary cases; summary reports the omission")
    return parser.parse_args()


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def cleanup(run):
    for path, mode in run.fixture_modes.items():
        Path(path).chmod(mode)
    status = run.s.call("get_status")
    assert not status.get("jobs"), "Wait for all isolated smoke jobs before cleanup"
    ours = [item for item in status["projects"] if item.get("yours")]
    # This helper's projects only; source-frame helpers may have left a failed scratch.
    for project in ours:
        path = project.get("path")
        assert path and Path(path).resolve().is_relative_to(run.work), "Refuse cleanup outside our dedicated workspace"
        run.s.call("close_project", {"project": project["id"]})
    after = run.s.call("get_status")
    assert not any(item.get("yours") for item in after["projects"])
    run.evidence("cleanup", {"closed_project_paths": [item["path"] for item in ours],
                             "pending_jobs": after.get("jobs"), "cloud_tasks": after.get("cloud_tasks"),
                             "isolated_app_server": "left running for root-owned cleanup"})


def finish(run):
    assert run.stage in ("rebound_reviewed", "refreshed_reviewed"), "Required source-change/rebind observations are still pending"
    run.case("state smoke complete: observations, persistence and recovery gating; zero admitted jobs")
    report = dict(cases=run.events, stage=run.stage, project_path=run.path,
                  native_boundaries=run.native_boundaries, credits_changed=run.s.spent() - run.cost_before,
                  admitted_provider_jobs=run.network.admitted() - run.admitted_before,
                  caller_recorded_visual_review=True, audio_numeric=True, audio_actually_auditioned=False,
                  preflight_is_output_review=False, service="isolated fake process",
                  production_activation="not changed; not verified by this fake test",
                  provider_concurrency="not exercised; second-helper ownership is a local isolation test",
                  financial_receipts="separate existing official.py recovery case; not claimed by this driver",
                  final_production=run.production())
    path = run.evidence("state-smoke-summary", report)
    cleanup(run)
    emit({"status": "complete", "summary": path, "app_and_server": "left running"})


def commands(run):
    from production_state_anchors import capture
    from production_state_invalidation import sound_then_trim, swap_and_rebind, verify_rebound_review
    from production_state_review import author_observations, collect
    emit({"status": "awaiting_review", "evidence": str(run.s.evidence), "stage": run.stage,
          "commands": ["author {reviews_file}", "invalidate", "refresh", "finish", "cleanup", "status"],
          "session": "Keep stdin open; supply one JSON command per line."})
    for line in sys.stdin:
        command = json.loads(line)
        assert isinstance(command, dict) and set(command) <= {"action", "reviews_file"}
        action = command.get("action")
        if action == "author":
            author_observations(run, command["reviews_file"])
            if run.stage == "rebound_reviewed":
                verify_rebound_review(run)
            if run.stage == "refreshed_reviewed":
                run.quote()
            emit({"status": run.stage, "next": "invalidate" if run.stage == "baseline_reviewed" else "finish or refresh"})
        elif action == "invalidate":
            sound_then_trim(run)
            swap_and_rebind(run)
            emit(collect(run, "rebound"))
        elif action == "refresh":
            assert run.stage == "rebound_reviewed"
            capture(run)
            emit(collect(run, "refreshed"))
        elif action == "status":
            emit({"stage": run.stage, "project": run.project, "evidence": str(run.s.evidence), "pending_review": bool(run.pending)})
        elif action == "finish":
            finish(run)
            return
        elif action == "cleanup":
            cleanup(run)
            emit({"status": "stopped_incomplete", "stage": run.stage, "evidence": str(run.s.evidence)})
            return
        else:
            raise ValueError("Unknown driver command")
    raise EOFError("Review/cleanup was not completed; own projects remain for deliberate follow-up")


def main():
    args = arguments()
    os.umask(0o077)
    sys.path.insert(0, str(args.support_dir.resolve()))
    sys.path.insert(0, str(args.native_dir.resolve()))
    import official_client as network
    from production_state_anchors import author_negatives, capture, native_boundary_cases, reference_chain_negative
    from production_state_review import collect
    from production_state_story import bind_outputs, lifecycle
    from production_state_support import StateRun, verify_contract
    assert os.environ.get("SKYSTUDIO_SMOKE_DIR"), "Root must select the exact isolated test directory"
    assert network.SERVER == "http://127.0.0.1:18766", "This driver is only for the dedicated fake server"
    assert network.WORK.is_dir() and all((network.WORK / name).is_file() for name in ("motion.mp4", "subject.png", "reference.wav"))
    # A read-only fake endpoint proves fixture service availability; no remote service is contacted.
    network.admitted()
    # A fresh fixture starts in ordinary-upload mode; native references need account-owned originals.
    network.control(official=True, official_failure=None, official_quote_seconds=300)
    session = network.Session()
    run = None
    try:
        verify_contract(session)
        run = StateRun(session, network.WORK, network)
        run.native_boundaries = not args.skip_native_boundaries
        lifecycle(run)
        bind_outputs(run)
        anchors = capture(run)
        author_negatives(run, anchors)
        reference_chain_negative(run, anchors)
        if run.native_boundaries:
            native_boundary_cases(run)
        emit(collect(run, "baseline"))
        commands(run)
    except BaseException as error:
        # Do not stringify unexpected tool exceptions: they may contain an ephemeral token.
        if run:
            run.evidence("driver-failed", {"error_type": type(error).__name__, "stage": run.stage,
                                           "stack": [{"file": frame.filename, "line": frame.lineno, "function": frame.name} for frame in traceback.extract_tb(error.__traceback__)],
                                           "cases": run.events, "project": run.project, "path": run.path,
                                           "cleanup": "not attempted; inspect owned jobs/projects before continuing"})
        emit({"status": "failed", "error_type": type(error).__name__, "evidence": str(session.evidence)})
        raise SystemExit(1) from None
    finally:
        session.close()  # Helper only. Do not touch shared bundle/socket or root-owned App/server.


if __name__ == "__main__":
    main()

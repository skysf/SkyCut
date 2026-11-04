"""Draft only: invoke from an already-owned background MCP session after the state PR.

This module does not launch an App, generate fixtures, decode media or contact a provider.
All actual import/edit/freeze/image reads are MCP calls. Keep its returned evidence JSON.
session.call must raise on tool errors; session.mcp.call returns (result, is_error).
"""
from fractions import Fraction
from pathlib import Path
import json
import math
import uuid


def native_time(value):
    assert set(value) == {"value", "timescale", "epoch", "flags", "seconds"}
    assert isinstance(value["value"], str) and str(int(value["value"])) == value["value"]
    assert type(value["timescale"]) in (int, float) and value["timescale"] > 0 and int(value["timescale"]) == value["timescale"]
    assert value["epoch"] == "0" and value["flags"] in (1, 3)
    rational = Fraction(int(value["value"]), int(value["timescale"]))
    assert rational >= 0
    assert math.isfinite(value["seconds"]) and value["seconds"] == float(rational)
    return rational


def inspect_evidence(value, source, case, project_time, strict_anchor):
    assert set(value) == {"version", "scope", "source_clip_uuid", "source_file", "source_file_identity",
                          "source_file_unchanged", "used_source_window", "requested_source_time", "actual_source_time",
                          "drift_source_seconds", "used_tolerance_fallback", "used_tolerance",
                          "requested_in_used_window", "actual_in_used_window", "image"}
    assert value["version"] == 1 and value["scope"] == "upright_source"
    uuid.UUID(value["source_clip_uuid"])
    # The fixture may use /private/tmp while SkyCut exposes its /tmp alias; native metadata stays unchanged.
    assert Path(value["source_file"]).resolve() == source.resolve() and value["source_file_unchanged"] is True
    identity = value["source_file_identity"]
    assert identity["path"] == value["source_file"] and int(identity["bytes"]) > 0
    assert set(identity) == {"path", "device", "inode", "bytes", "modified"}
    window = value["used_source_window"]
    expected_window = dict(start=case["source_in"], duration=case["source_out"] - case["source_in"],
                           end=case["source_out"])
    assert window["bounds"] == "half_open"
    for key, expected in expected_window.items():
        assert math.isclose(window[key], expected, rel_tol=0, abs_tol=1e-12), (key, window, expected_window)
    requested = native_time(value["requested_source_time"])
    actual = native_time(value["actual_source_time"])  # Never derive actual from requested + drift.
    assert value["requested_source_time"]["timescale"] == 600
    assert int(value["requested_source_time"]["value"]) == case["requested_ticks"]
    expected_source = case["source_in"] + (project_time - case["start"]) * case["speed"]
    assert abs(float(requested) - expected_source) <= 1 / 600 + 1e-12
    assert math.isclose(value["drift_source_seconds"], float(actual - requested), rel_tol=0, abs_tol=1e-12)
    requested_inside = window["start"] <= float(requested) < window["end"]
    actual_inside = window["start"] <= float(actual) < window["end"]
    assert value["requested_in_used_window"] is requested_inside
    assert value["actual_in_used_window"] is actual_inside
    if strict_anchor:
        assert requested_inside and actual_inside
        assert abs(float(actual - requested)) <= 0.5 / 24 * case["speed"] + 1e-12
    tolerance = native_time(value["used_tolerance"])
    assert tolerance >= 0
    if value["used_tolerance_fallback"] is False:
        assert tolerance == 0
    else:
        assert 0 < float(tolerance) <= 0.5 / 24 * case["speed"] + 1 / 600
    image = value["image"]
    assert set(image) == {"file", "file_identity"}
    assert Path(image["file"]).is_absolute() and Path(image["file"]).suffix.lower() == ".png"
    assert image["file_identity"]["path"] == image["file"] and int(image["file_identity"]["bytes"]) > 0
    return actual != requested


def checkpoint(session, label, value):
    """Persist only local MCP evidence; never reopen/decode media outside MCP."""
    folder = Path(session.evidence)
    assert folder.is_absolute() and folder.is_dir(), "Use the existing owned evidence directory"
    path = folder / (label + ".json")
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    path.chmod(0o600)
    return str(path)


def owned_background(session, project):
    status = session.call("get_status", {"project": project})
    owned = next(item for item in status["projects"] if item["id"] == project)
    assert owned["yours"] and owned["view"] == "background" and owned["shown_in"] == "background (no window)", owned


def run(session, workspace, source_name="motion.mp4"):
    workspace = Path(workspace)
    assert workspace.is_absolute(), "Use the already-owned isolated fixture workspace"
    assert not Path(source_name).is_absolute() and ".." not in Path(source_name).parts
    source = workspace / source_name
    session.call("set_view", {"mode": "background"})
    session.call("open_folder", {"path": str(workspace)})
    evidence, distinct_native_time = [], False
    cases = [
        dict(name="trim-first", source_in=0.5, source_out=1.7, speed=1, start=0, edge="first", requested_ticks=300),
        dict(name="trim-last", source_in=0.5, source_out=1.7, speed=1, start=0, edge="last", requested_ticks=1000),
        dict(name="fractional-fast-first", source_in=0.5, source_out=1.7, speed=2, start=0.02, edge="first", requested_ticks=326),
        dict(name="fractional-fast-last", source_in=0.5, source_out=1.7, speed=2, start=0.02, edge="last", requested_ticks=976),
        dict(name="quantized-before-use", source_in=1.0009, source_out=1.3009, speed=1, start=0, edge="first", requested_ticks=600),
        dict(name="half-open-rejection", source_in=0.5, source_out=1.7, speed=2, start=0.02, edge="excluded_end")
    ]
    for case in cases:
        label = "native-" + case["name"] + "-" + uuid.uuid4().hex[:8]
        project = session.call("new_project", dict(folder=str(workspace), name="Source frame smoke",
                                                     version=label))["project"]
        owned_background(session, project)
        session.call("set_canvas", dict(project=project, fps=24))
        # V2 avoids remembered main-track magnetic packing changing a fractional timeline start.
        session.call("add_clips", dict(project=project, clips=[dict(file=str(source), track="V2", start=case["start"],
                                                                  source_in=case["source_in"], source_out=case["source_out"])]))
        initial = session.call("get_timeline", {"project": project})
        clips = [clip for track in initial["tracks"] for clip in track["clips"]]
        assert len(clips) == 1 and clips[0]["kind"] == "video"
        clip_id = clips[0]["id"]
        session.call("edit_clip", dict(project=project, clip_id=clip_id, speed=case["speed"], start=case["start"]))
        before = session.call("get_timeline", {"project": project})
        assert before["fps"] == 24
        actual_clip = next(item for track in before["tracks"] for item in track["clips"] if item["id"] == clip_id)
        assert actual_clip["start"] == case["start"] and actual_clip.get("speed", 1) == case["speed"]
        # get_timeline is rounded for display; exact source geometry is checked in native source_frame below.
        assert abs(actual_clip["source_in"] - case["source_in"]) <= 0.001
        assert abs(actual_clip["source_out"] - case["source_out"]) <= 0.001
        duration = (case["source_out"] - case["source_in"]) / case["speed"]
        end = case["start"] + duration
        if case["edge"] == "excluded_end":
            response, error = session.mcp.call("freeze_frame", dict(project=project, clip_id=clip_id, time=end, duration=0.2), timeout=90)
            raw_path = checkpoint(session, label + "-raw", dict(case=case, project=project, project_time=end,
                                                               response=response, is_error=error))
            assert error, "The exact half-open timeline end must be rejected"
            after = session.call("get_timeline", {"project": project})
            assert after["tracks"] == before["tracks"] and after["duration"] == before["duration"]
            evidence.append(dict(case=case["name"], geometry=case, project=project, rejected=True,
                                 response=response, raw_evidence=raw_path))
        else:
            project_time = math.ceil(case["start"] * 24) / 24 if case["edge"] == "first" else (math.ceil(end * 24) - 1) / 24
            assert case["start"] <= project_time < end
            frozen, error = session.mcp.call("freeze_frame", dict(project=project, clip_id=clip_id, time=project_time, duration=0.2), timeout=90)
            raw_path = checkpoint(session, label + "-raw", dict(case=case, project=project, project_time=project_time,
                                                               response=frozen, is_error=error))
            assert not error, frozen
            frame = frozen["source_frame"]
            strict = case["name"] != "quantized-before-use"
            different = inspect_evidence(frame, source, case, project_time, strict_anchor=strict)
            distinct_native_time = distinct_native_time or (strict and different)
            if not strict:
                assert frame["requested_in_used_window"] is False, "Ordinary freeze must truthfully report an unusable anchor"
            # Only the returned native PNG is the potential anchor; the contact sheet is separate review evidence.
            picture = session.call("look", dict(project=project, file=frame["image"]["file"], count=1, image=False))
            assert picture["frames"] and picture["image"]["width"] > 0 and picture["image"]["height"] > 0
            session.look(dict(project=project, file=frame["image"]["file"], count=1), label + "-png-review")
            evidence.append(dict(case=case["name"], geometry=case, project=project, project_time=project_time,
                                 strict_anchor_candidate=strict, source_frame=frame, picture=picture, raw_evidence=raw_path,
                                 production_anchor_validation="pending", requires_author_refusal=not strict))
        owned_background(session, project)
        session.call("save_project", {"project": project})
        session.call("close_project", {"project": project})
        checkpoint(session, label + "-checked", evidence[-1])
    assert distinct_native_time, "The run must demonstrate at least one independently reported actual/requested timestamp difference"
    checkpoint(session, "native-source-frame-summary-" + uuid.uuid4().hex[:8], evidence)
    return evidence

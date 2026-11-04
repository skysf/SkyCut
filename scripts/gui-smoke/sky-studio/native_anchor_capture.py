"""Collect a native anchor from an owned bound output via background MCP only.

Uses exact on-demand source_geometry from the current production snapshot. It does
not author reviews, upload, quote, launch an App, decode files, or modify stat data.
Successful scratch projects close; failures retain the owned project and raw reply.
"""
import base64
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import uuid

from mcp_source_frame_smoke import checkpoint, native_time, owned_background


GEOMETRY_KEYS = {"source_file", "source_in", "source_out", "source_duration", "speed", "timeline_start", "fps",
                 "first_project_time", "last_project_time"}


def equivalent_path(left, right):
    # Path alias comparison only (/private/tmp versus /tmp); never invent a file identity.
    return os.path.realpath(left) == os.path.realpath(right)


def supports_exact_in_out(geometry):
    """The in/out import must preserve the native stored duration, even by one ULP."""
    return geometry["source_out"] - geometry["source_in"] == geometry["source_duration"]


def bound_source(session, source_project, from_shot_id, workspace):
    owned_background(session, source_project)
    timeline = session.call("get_timeline", {"project": source_project})
    production = timeline.get("production")
    assert production and "plan" in production, "The source project needs a valid authored production plan"
    shots = [shot for shot in production["plan"]["shots"] if shot["film"]["shot"]["id"] == from_shot_id]
    rows = [row for row in production["expected_snapshots"]["shots"] if row["shot_id"] == from_shot_id]
    assert len(shots) == len(rows) == 1, "from_shot_id must identify one current authoritative shot"
    shot, row = shots[0], rows[0]
    binding = row.get("output_binding")
    assert isinstance(binding, str) and re.fullmatch(r"[0-9a-f]{64}", binding)
    assert shot.get("clip_id") and shot.get("output_binding") == binding, "Rebind the changed output explicitly before sampling"
    geometry = row.get("source_geometry")
    assert isinstance(geometry, dict) and set(geometry) == GEOMETRY_KEYS, "Exact public source_geometry is required; do not infer it from rounded timeline text"
    assert isinstance(geometry["source_file"], str) and Path(geometry["source_file"]).is_absolute()
    for name in ["source_in", "source_out", "source_duration", "speed", "timeline_start", "fps"]:
        assert type(geometry[name]) in (int, float) and math.isfinite(geometry[name]), name
    assert geometry["source_in"] >= 0 and geometry["source_duration"] > 0 and geometry["speed"] > 0
    assert geometry["timeline_start"] >= 0 and geometry["fps"] in (24, 30, 60)
    assert geometry["source_out"] == geometry["source_in"] + geometry["source_duration"]
    # The existing add_clips API accepts in/out. If it cannot recreate the exact
    # stored duration, fail rather than weakening the later exact-window check.
    assert supports_exact_in_out(geometry), "This exact used window cannot be recreated through in/out; do not rewrite its native metadata"
    clips = [clip for track in timeline["tracks"] for clip in track["clips"] if clip["id"] == shot["clip_id"]]
    assert len(clips) == 1 and clips[0]["kind"] == "video", "A native anchor needs one current video output"
    clip = clips[0]
    shown_file = Path(clip["file"])
    if not shown_file.is_absolute():
        shown_file = Path(workspace) / shown_file
    assert equivalent_path(str(shown_file), geometry["source_file"])
    assert timeline["fps"] == geometry["fps"] and clip.get("speed", 1) == geometry["speed"]
    for shown, exact in [("start", "timeline_start"), ("source_in", "source_in"), ("source_out", "source_out")]:
        assert abs(clip[shown] - geometry[exact]) <= 0.000500000001, "Rounded display and exact source geometry disagree"
    return {"clip_id": shot["clip_id"], "output_binding": binding, "source_geometry": geometry}


def check_native(frame, geometry, project_time):
    assert set(frame) == {"version", "scope", "source_clip_uuid", "source_file", "source_file_identity",
                          "source_file_unchanged", "used_source_window", "requested_source_time", "actual_source_time",
                          "drift_source_seconds", "used_tolerance_fallback", "used_tolerance",
                          "requested_in_used_window", "actual_in_used_window", "image"}
    assert frame["version"] == 1 and frame["scope"] == "upright_source"
    uuid.UUID(frame["source_clip_uuid"])
    # Exact native identity path must agree, even when a UI display used an alias.
    assert frame["source_file"] == geometry["source_file"] and frame["source_file_unchanged"] is True
    identity = frame["source_file_identity"]
    assert set(identity) == {"path", "device", "inode", "bytes", "modified"}
    assert identity["path"] == frame["source_file"] and int(identity["bytes"]) > 0
    assert frame["used_source_window"] == {
        "start": geometry["source_in"], "duration": geometry["source_duration"],
        "end": geometry["source_out"], "bounds": "half_open"}
    requested = native_time(frame["requested_source_time"])
    actual = native_time(frame["actual_source_time"])  # Never derive actual from drift or request.
    assert frame["requested_source_time"]["timescale"] == 600
    position = geometry["source_in"] + (project_time - geometry["timeline_start"]) * geometry["speed"]
    assert abs(float(requested) - position) <= 1 / 600 + 1e-12
    for value in [requested, actual]:
        assert geometry["source_in"] <= float(value) < geometry["source_out"], "Native timestamp is outside the exact half-open used window"
    assert frame["requested_in_used_window"] is True and frame["actual_in_used_window"] is True
    assert math.isclose(frame["drift_source_seconds"], float(actual - requested), rel_tol=0, abs_tol=1e-12)
    half_frame = 0.5 / geometry["fps"] * geometry["speed"]
    assert abs(float(actual - requested)) <= half_frame + 1e-12
    tolerance = native_time(frame["used_tolerance"])
    assert type(frame["used_tolerance_fallback"]) is bool
    if frame["used_tolerance_fallback"]:
        assert 0 <= float(tolerance) <= max(half_frame, 0.001) + 1 / 600
    else:
        assert tolerance == Fraction(0)
    image = frame["image"]
    assert set(image) == {"file", "file_identity"} and Path(image["file"]).is_absolute()
    assert Path(image["file"]).suffix.lower() == ".png"
    assert set(image["file_identity"]) == {"path", "device", "inode", "bytes", "modified"}
    assert image["file_identity"]["path"] == image["file"] and int(image["file_identity"]["bytes"]) > 0


def collect_contact_sheet(session, project, image_file, label):
    # Collect actual MCP output for root to view later. Black images are still
    # evidence; no brightness threshold or automatic visual-review assertion.
    reply = session.mcp.request("tools/call", {"name": "look", "arguments": {
        "project": project, "file": image_file, "count": 1, "image": True}}, timeout=90)["result"]
    assert not reply.get("isError"), reply
    content = reply["content"]
    metadata = json.loads(next(item["text"] for item in content if item["type"] == "text"))
    images = [item for item in content if item["type"] == "image"]
    assert metadata.get("frames") and images, "MCP did not return its actual PNG review image"
    paths = []
    for index, item in enumerate(images):
        suffix = {"image/png": ".png", "image/jpeg": ".jpg"}[item["mimeType"]]
        path = Path(session.evidence) / (label + "-contact-" + str(index) + suffix)
        with path.open("xb") as stream:
            stream.write(base64.b64decode(item["data"], validate=True))
        path.chmod(0o600)
        paths.append(str(path))
    checkpoint(session, label + "-look", metadata)
    return paths


def capture_bound_anchor(session, workspace, *, source_project, from_shot_id, role, source_edge, label=None):
    """Return a PNG/role plus untouched native metadata; not an authored anchor.

    The exact row comes from current get_timeline.production.expected_snapshots.
    Success closes only this new scratch project. Failure preserves it and raw
    replies for inspection; the caller owns final App/session cleanup.
    """
    workspace = Path(workspace)
    assert workspace.is_absolute() and role in ("first", "last") and source_edge in ("first_used", "last_used")
    label = (label or "native-anchor") + "-" + uuid.uuid4().hex[:8]
    assert re.fullmatch(r"[A-Za-z0-9_-]{1,96}", label)
    original = bound_source(session, source_project, from_shot_id, workspace)
    geometry = original["source_geometry"]
    project_time = geometry["first_project_time" if source_edge == "first_used" else "last_project_time"]
    assert type(project_time) in (int, float) and math.isfinite(project_time), "This used window has no project-grid frame"
    end = geometry["timeline_start"] + geometry["source_duration"] / geometry["speed"]
    assert geometry["timeline_start"] <= project_time < end
    assert abs(project_time * geometry["fps"] - round(project_time * geometry["fps"])) <= 1e-8
    session.call("open_folder", {"project": source_project, "path": str(workspace)})
    session.call("set_view", {"project": source_project, "mode": "background"})
    created = session.call("new_project", {"folder": str(workspace), "name": "Native anchor scratch", "version": label})
    scratch = created["project"]
    assert scratch != source_project
    owned_background(session, scratch)
    project_file = created["created"]
    assert Path(os.path.realpath(project_file)).is_relative_to(Path(os.path.realpath(workspace)))
    checkpoint(session, label + "-scratch", {"source_project": source_project, "from_shot_id": from_shot_id,
                                            "source": original, "created": created})
    session.call("set_canvas", {"project": scratch, "fps": geometry["fps"]})
    session.call("add_clips", {"project": scratch, "clips": [{"file": geometry["source_file"], "track": "V2",
        "start": geometry["timeline_start"], "source_in": geometry["source_in"], "source_out": geometry["source_out"]}]})
    timeline = session.call("get_timeline", {"project": scratch})
    clips = [clip for track in timeline["tracks"] for clip in track["clips"]]
    assert len(clips) == 1 and clips[0]["kind"] == "video"
    clip_id = clips[0]["id"]
    session.call("edit_clip", {"project": scratch, "clip_id": clip_id,
                               "speed": geometry["speed"], "start": geometry["timeline_start"]})
    before = session.call("get_timeline", {"project": scratch})
    clip = next(clip for track in before["tracks"] for clip in track["clips"] if clip["id"] == clip_id)
    assert before["fps"] == geometry["fps"] and clip.get("speed", 1) == geometry["speed"]
    assert abs(clip["start"] - geometry["timeline_start"]) <= 0.000500000001
    response, error = session.mcp.call("freeze_frame", {"project": scratch, "clip_id": clip_id,
        "time": project_time, "duration": 1 / geometry["fps"]}, timeout=90)
    raw = checkpoint(session, label + "-raw-freeze", {"project": scratch, "requested_project_time": project_time,
                                                    "source_geometry": geometry, "response": response, "is_error": error})
    assert not error, response
    frame = response["source_frame"]
    check_native(frame, geometry, project_time)
    png = frame["image"]["file"]
    assert equivalent_path(str(Path(png).parent), str(Path(project_file).parent))
    contacts = collect_contact_sheet(session, scratch, png, label)
    assert bound_source(session, source_project, from_shot_id, workspace) == original, "The authoritative source changed while sampling; do not reuse the candidate"
    owned_background(session, scratch)
    session.call("save_project", {"project": scratch})
    session.call("close_project", {"project": scratch})
    result = {"role": role, "source_edge": source_edge, "from_shot_id": from_shot_id,
              "reference_role": "first_frame" if role == "first" else "last_frame",
              "generation_argument": "image" if role == "first" else "last_image",
              "file": png, "source_frame": frame, "source_geometry": geometry,
              "source_project": source_project, "source_output_binding": original["output_binding"],
              "requested_project_time": project_time, "raw_evidence": raw,
              "scratch_project": scratch, "scratch_project_path": project_file, "scratch_closed": True,
              "contact_sheets": contacts, "visual_review_status": "pending_root_review",
              "production_anchor_validation": "pending_prepare_and_author"}
    checkpoint(session, label + "-candidate", result)
    return result


if __name__ == "__main__":
    raise SystemExit("Import capture_bound_anchor into an already-owned MCP session; this helper does not launch one.")

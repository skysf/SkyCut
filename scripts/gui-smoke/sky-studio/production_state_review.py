"""Collect MCP contact sheets/mixed-audio numbers, then accept actual reviewer notes.

Collection does not mark media reviewed. A live driver pauses until a reviewer has
opened the saved MCP images and supplies this manifest's explicit observations.
"""
from copy import deepcopy
import json
import math
from pathlib import Path

from production_state_support import digest, keyed, save_json


def pictures(run, arguments, label):
    values, images = [], []
    times = arguments.pop("times")
    assert times and len(times) <= 128
    for index in range(0, len(times), 12):
        stem = label + "-" + str(index // 12)
        value = run.s.look({**arguments, "times": times[index:index + 12], "image": True}, stem)
        values.append(value)
        files = sorted(path for path in run.s.evidence.glob(stem + "-*") if path.suffix in (".png", ".jpg"))
        assert files, "No actual MCP image bytes were saved"
        images.extend(map(str, files))
    return dict(images=images, metadata=values, requested_times=times)


def collect(run, phase):
    production = run.production()
    expected = production["expected_snapshots"]
    rows = keyed(expected["shots"])
    readiness = keyed(production["readiness"]["shots"])
    shots, seams = {}, {}
    for index, shot in enumerate(production["plan"]["shots"]):
        shot_id = shot["film"]["shot"]["id"]
        row, ready = rows[shot_id], readiness[shot_id]
        assert not ready["required_action_samples"], "This static fixture must not invent a visible action"
        geometry = row["source_geometry"]
        source = pictures(run, dict(project=run.project, file=geometry["source_file"], times=ready["required_source_times"]),
                          phase + "-source-" + shot_id)
        shots[shot_id] = dict(source_snapshot=row["source_snapshot"], output_binding=row["output_binding"],
                             source_geometry=geometry, source_times=ready["required_source_times"], evidence=source)
        if index + 1 < len(production["plan"]["shots"]):
            following = production["plan"]["shots"][index + 1]["film"]["shot"]["id"]
            name = shot_id + "->" + following
            assert row["next_snapshot"] == rows[following]["previous_snapshot"]
            seam = pictures(run, dict(project=run.project, times=row["next_timeline_times"]),
                            phase + "-seam-" + str(index))
            seams[name] = dict(snapshot=row["next_snapshot"], timeline_times=row["next_timeline_times"], evidence=seam)
    export = run.s.call("export_video", {"project": run.project, "preset": "quick_review", "name": run.tag + "-" + phase})
    exported = run.s.wait(export["job_id"])
    file = exported["path"]
    cue = production["plan"]["sound_cues"][0]
    levels = run.s.call("listen", {"project": run.project, "file": file, "source_in": cue["at"],
                                  "source_out": cue["at"] + cue["duration"]})
    assert all(type(levels.get(key)) in (float, int) and math.isfinite(levels[key]) for key in ("level_db", "peak_db")), levels
    assert levels["level_db"] > -60 and levels["to"] > levels["from"], "Expected audible synthetic exported mix"
    inspect = run.s.call("inspect_video", {"project": run.project, "file": file, "from": 0, "to": 4.5, "image": False})
    inspected = run.s.wait(inspect["job_id"])
    assert "coverage_complete" in inspected and "findings" in inspected, "Inspection must report actual coverage"
    export_path = run.evidence(phase + "-export", exported)
    listen_path = run.evidence(phase + "-listen-exported-mix", levels)
    inspect_path = run.evidence(phase + "-inspection", inspected)
    # Detect changes during async rendering/analysis before declaring this a reviewable snapshot.
    assert run.production()["expected_snapshots"] == expected, "Timeline changed during evidence collection"
    manifest = dict(phase=phase, project_path=run.path, revision=production["revision"], expected_snapshots=expected,
                    shots=shots, seams=seams,
                    mix=dict(file=file, level_db=levels["level_db"], peak_db=levels["peak_db"],
                             export_evidence=export_path, numeric_evidence=listen_path, inspection_evidence=inspect_path,
                             inspection_coverage_complete=inspected["coverage_complete"]),
                    native_anchor_contacts=getattr(run, "anchor_contacts", []),
                    visual_review_status="pending_actual_image_review", listened_note=None,
                    requested_times_are_actual_decoded_times=False)
    manifest["manifest_id"] = digest(manifest)
    run.pending = manifest
    run.stage = "awaiting_" + phase + "_review"
    manifest_path = run.evidence(phase + "-review-manifest", manifest)
    template = dict(manifest_id=manifest["manifest_id"], reviewer=None, viewed_images=[],
                    sources={key: {"notes": None} for key in shots}, seams={key: {"notes": None} for key in seams})
    template_path = run.evidence(phase + "-review-template", template)
    run.case("MCP source/both-seam images and exported mix numbers collected; actual visual review pending", manifest)
    return {"manifest": manifest_path, "review_template": template_path, "phase": phase,
            "next": "View every manifest image, fill a separate review JSON, then send author with reviews_file."}


def read_observations(path, manifest):
    observations = json.loads(Path(path).read_text())
    assert set(observations) == {"manifest_id", "reviewer", "viewed_images", "sources", "seams"}
    assert observations["manifest_id"] == manifest["manifest_id"]
    assert isinstance(observations["reviewer"], str) and observations["reviewer"].strip(), "Name the actual reviewing agent/person"
    all_images = {file for group in (manifest["shots"], manifest["seams"]) for row in group.values() for file in row["evidence"]["images"]}
    all_images.update(manifest.get("native_anchor_contacts", []))
    assert all_images <= set(observations["viewed_images"]), "Every source and composed-seam image needs actual review"
    for group, expected in (("sources", manifest["shots"]), ("seams", manifest["seams"])):
        assert set(observations[group]) == set(expected)
        for entry in observations[group].values():
            assert set(entry) == {"notes"} and isinstance(entry["notes"], str) and 1 <= len(entry["notes"].strip()) <= 1000
    return observations


def author_observations(run, reviews_file):
    manifest = run.pending
    assert manifest and run.stage == "awaiting_" + manifest["phase"] + "_review"
    observations = read_observations(reviews_file, manifest)
    current = run.production()
    assert current["expected_snapshots"] == manifest["expected_snapshots"], "Review snapshots have changed; collect again"
    plan = deepcopy(current["plan"])
    for index, shot in enumerate(plan["shots"]):
        shot_id = shot["film"]["shot"]["id"]
        source = manifest["shots"][shot_id]
        review = dict(source_times=source["source_times"], source_snapshot=source["source_snapshot"],
                      notes=observations["sources"][shot_id]["notes"], action_samples=[], previous=None, next=None)
        for side, offset in (("previous", -1), ("next", 1)):
            other = index + offset
            if 0 <= other < len(plan["shots"]):
                other_id = plan["shots"][other]["film"]["shot"]["id"]
                key = other_id + "->" + shot_id if side == "previous" else shot_id + "->" + other_id
                seam = manifest["seams"][key]
                review[side] = dict(snapshot=seam["snapshot"], timeline_times=seam["timeline_times"], notes=observations["seams"][key]["notes"])
        shot["output_review"] = review
    mix = manifest["mix"]
    snapshots = keyed(manifest["expected_snapshots"]["sound_cues"], "id")
    for cue in plan["sound_cues"]:
        cue["alignment"] = dict(snapshot=snapshots[cue["id"]]["snapshot"], listened_note=None,
                                 measured_note=f"MCP listen on exported mix: RMS {mix['level_db']} dBFS, peak {mix['peak_db']} dBFS; evidence {Path(mix['numeric_evidence']).name}.")
    result = run.save(plan)
    assert all(shot["output_observations_current"] for shot in result["readiness"]["shots"])
    assert all(cue["measured_current"] and not cue["listened_current"] and not cue["listened_recorded"]
               for cue in result["readiness"]["sound_cues"])
    run.evidence(manifest["phase"] + "-reviewer-observations", observations)
    run.stage = manifest["phase"] + "_reviewed"
    run.pending = None
    run.last_mix_file = manifest["mix"]["file"]
    run.case("actual reviewer observations saved; numeric mix current and subjective listening absent", result)
    return result

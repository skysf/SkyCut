"""Public synthetic storyboard + MCP author lifecycle. No fictional action observation."""
from copy import deepcopy
import os
from pathlib import Path
import stat

from production_smoke import full_plan
from production_state_support import media_rows, unchanged_timeline


def abstract_plan(prepared):
    context = dict(environment="interior", light_source="practical", shot_task="establish_space")
    state = dict(actor_position="no actor", hand="none", grip="none", prop_location="none",
                 action_phase="steady abstract field", spatial_relation="flat field", gaze="none",
                 screen_direction="none", lighting="uniform steel blue", completed_actions=["field_established"])
    render = {**deepcopy(prepared["prepared_render"]), "context": context}
    film = dict(intent="original_film", category="science_fiction", footage="none", context=context,
                shot=dict(id="shot-b", index=1, total=3, revision=1, entry=state, exit=state, actions=[]),
                sound=dict(bed_id="synthetic-reference", music="none", environment="synthetic spoken reference bed",
                           foley="none; no visible action"),
                previous=dict(shot_id="shot-a", render=render, sound_bed_id="synthetic-reference", cut=dict(type="continuous"), exit=state),
                next=dict(shot_id="shot-c", render=render, sound_bed_id="synthetic-reference", cut=dict(type="continuous"), entry=state))
    plan = full_plan(film, render)
    plan["story"] = "Original abstract blue-field fixture; three used windows, no newly visible action."
    plan["sound_cues"] = [dict(id="synthetic-bed", shot_ids=["shot-a", "shot-b", "shot-c"],
                               layer="environment", purpose="Continuous synthetic spoken reference for numeric mix inspection", at=0, duration=4.5)]
    return plan


def rewire(plan, old):
    """Refresh explicit neighbor declarations and only legally changed shot revisions."""
    plan = deepcopy(plan)
    for index, row in enumerate(plan["shots"]):
        film = row["film"]
        for side, offset, boundary in (("previous", -1, "exit"), ("next", 1, "entry")):
            other = index + offset
            if 0 <= other < len(plan["shots"]):
                neighbor = plan["shots"][other]
                film[side] = {**film[side], "shot_id": neighbor["film"]["shot"]["id"],
                              "render": deepcopy(neighbor["render"]), boundary: deepcopy(neighbor["film"]["shot"][boundary]),
                              "sound_bed_id": neighbor["film"]["sound"]["bed_id"]}
        prior = old["shots"][index]
        film["shot"]["revision"] = prior["film"]["shot"]["revision"]
        if film != prior["film"] or row["render"] != prior["render"]:
            film["shot"]["revision"] += 1
    return plan


def authored_save_failure(run):
    before = run.production()
    parent = run.work / (run.tag + "-nonwritable-save-parent")
    parent.mkdir(mode=0o700)
    original_mode = stat.S_IMODE(parent.stat().st_mode)
    run.fixture_modes[str(parent)] = original_mode
    destination = parent / "requested-save.skycut"
    run.evidence("save-failure-fixture", {"parent": str(parent), "restore_mode": original_mode, "destination": str(destination)})
    plan = deepcopy(before["plan"])
    plan["story"] += " Author committed before the requested disk save failed."
    try:
        parent.chmod(0o500)
        assert not os.access(parent, os.W_OK), "POSIX fixture is writable; do not report a disk-save failure test"
        value, error = run.s.mcp.call("save_project", {"project": run.project, "expected_revision": before["revision"],
            "production": plan, "path": str(destination)}, timeout=90)
        assert error and value["status"] == "production_authored_save_failed"
        assert value["production_authored"] is True and value["requested_save_succeeded"] is False
        after = run.production()
        assert after["revision"] == before["revision"] + 1 and after["plan"]["story"] == plan["story"]
        assert not destination.exists(), "Failed requested path unexpectedly exists"
        status = run.s.call("get_status", {"project": run.project})
        assert Path(status["project"]["path"]).resolve() == Path(run.path).resolve(), "Failed Save As changed document identity"
        run.evidence("authored-save-failed", {"result": value, "authored": after, "original_project_path": run.path})
        run.s.call("undo", {"project": run.project, "steps": 1})
        assert run.production() == before, "One own undo must restore authored content after IO failure"
    finally:
        parent.chmod(original_mode)
    run.case("requested disk save failure reports retained authoring; original identity and single undo remain valid")


def lifecycle(run):
    s = run.s
    s.call("open_folder", {"path": str(run.work)})
    s.call("set_view", {"mode": "background"})
    run.sentinel, run.sentinel_path = run.new("Production sentinel")
    run.sentinel_before = unchanged_timeline(s.call("get_timeline", {"project": run.sentinel}))
    run.project, run.path = run.new("Production state")
    s.call("set_canvas", {"project": run.project, "fps": 24})
    run.base, run.prepared = run.prepare(run.work / "subject.png", run.work / "subject.png")
    first = run.save(abstract_plan(run.prepared))
    assert first["revision"] == 1
    assert all("output_missing_or_unusable" in row["findings"] for row in first["readiness"]["shots"])
    assert first["readiness"]["preflight_is_output_review"] is False
    assert run.save(first["plan"]) == first
    changed = deepcopy(first["plan"])
    changed["story"] += " Story text revised once."
    second = run.save(changed)
    assert second["revision"] == 2 and run.save(second["plan"]) == second
    run.refuse_plan(second["plan"], expected=1)
    for expected in (0, None):
        run.refused("save_project", {"project": run.project, "expected_revision": expected})
    malformed = deepcopy(second["plan"])
    malformed["shots"][-1]["film"]["shot"]["total"] = 4
    run.refuse_plan(malformed)
    replay = deepcopy(second["plan"])
    replay["shots"][1]["film"]["shot"]["actions"] = ["field_established"]
    replay["shots"][1]["film"]["shot"]["revision"] += 1
    run.refuse_plan(replay)
    foley = deepcopy(second["plan"])
    foley["sound_cues"].append(dict(id="wrong-foley", shot_ids=["shot-b"], layer="foley", purpose="Invalid replay guard",
                                      at=1.5, duration=0.25, action_id="field_established"))
    run.refuse_plan(foley)
    s.call("undo", {"project": run.project, "steps": 1})
    assert run.production() == first, "No-op/refusals must not consume an undo step"
    authored_save_failure(run)
    s.call("save_project", {"project": run.project})
    run.reopen()
    assert run.save(run.production()["plan"]) == run.production()
    # A second real helper is deliberately denied; it never opens/claims this project's path.
    from official_client import APP, MCP, os
    other = MCP(str(APP / "Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
    try:
        for tool, args in [("get_timeline", {}), ("save_project", {}), ("undo", {"steps": 1})]:
            _, error = other.call(tool, {"project": run.project, **args}, timeout=30)
            assert error, "A second helper gained access to an actively owned project"
    finally:
        other.close()
    run.case("atomic CAS, no-op undo, completed-action/foley refusal, reopen and second-helper ownership", first)


def bind_outputs(run):
    s = run.s
    s.call("add_clips", {"project": run.project, "clips": [
        dict(file="motion.mp4", track="V1", start=index * 1.5, source_in=0, source_out=1.5) for index in range(3)]
        + [dict(file="reference.wav", track="A1", start=0, source_in=0, source_out=4.5)]})
    timeline = run.read()
    pictures, audio = media_rows(timeline, "V1"), media_rows(timeline, "A1")
    assert len(pictures) == 3 and len(audio) == 1 and timeline["fps"] == 24
    plan = deepcopy(timeline["production"]["plan"])
    for row, clip in zip(plan["shots"], pictures):
        row["clip_id"] = clip["id"]
    plan["sound_cues"][0]["audio_clip_id"] = audio[0]["id"]
    current = run.save(plan)
    assert all(row.get("source_geometry") for row in current["expected_snapshots"]["shots"])
    assert all(row["output_observations_current"] is False for row in current["readiness"]["shots"])
    run.case("three synthetic actual outputs and a sound cue bound through MCP; observations still pending", current)


def apply_prepared_anchors(run, anchors, base, prepared):
    old = run.production()["plan"]
    plan = deepcopy(old)
    middle = plan["shots"][1]
    middle["render"] = {**deepcopy(prepared["prepared_render"]), "context": deepcopy(middle["film"]["context"])}
    middle["anchors"] = [dict(role=item["role"], source_edge=item["source_edge"], from_shot_id=item["from_shot_id"],
                              asset_url=prepared["inputs"]["image_url" if item["role"] == "first" else "last_frame_url"],
                              source_frame=deepcopy(item["source_frame"])) for item in anchors]
    result = run.save(rewire(plan, old))
    run.base, run.prepared = base, prepared
    assert result["readiness"]["shots"][1]["input_anchor_current"] is True
    return result

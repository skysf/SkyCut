"""Draft MCP-only authoring helper for the official fake smoke; never starts a provider job.

Integrate next slice before official quote. The current script uses returned film revision,
then submits the same plan/request. All three fixtures are original public synthetic stories.
"""
from copy import deepcopy
import math


def full_plan(film, render, previous=None):
    current = deepcopy(film)
    render = {**deepcopy(render), "context": deepcopy(current["context"])}
    previous_neighbor = current["previous"]
    next_neighbor = current["next"]
    bed = current["sound"]
    before = dict(intent=current["intent"], category=current["category"], footage=current["footage"],
                  context=deepcopy(previous_neighbor["render"]["context"]),
                  shot=dict(id=previous_neighbor["shot_id"], index=0, total=3, revision=1,
                            entry=deepcopy(previous_neighbor["exit"]), exit=deepcopy(previous_neighbor["exit"]), actions=[]),
                  sound={**deepcopy(bed), "bed_id": previous_neighbor["sound_bed_id"]},
                  next=dict(shot_id=current["shot"]["id"], render=deepcopy(render), sound_bed_id=bed["bed_id"],
                            cut=deepcopy(previous_neighbor["cut"]), entry=deepcopy(current["shot"]["entry"])))
    after = dict(intent=current["intent"], category=current["category"], footage=current["footage"],
                 context=deepcopy(next_neighbor["render"]["context"]),
                 shot=dict(id=next_neighbor["shot_id"], index=2, total=3, revision=1,
                           entry=deepcopy(next_neighbor["entry"]), exit=deepcopy(next_neighbor["entry"]), actions=[]),
                 sound={**deepcopy(bed), "bed_id": next_neighbor["sound_bed_id"]},
                 previous=dict(shot_id=current["shot"]["id"], render=deepcopy(render), sound_bed_id=bed["bed_id"],
                               cut=deepcopy(next_neighbor["cut"]), exit=deepcopy(current["shot"]["exit"])))
    pairs = [(before, previous_neighbor["render"]), (current, render), (after, next_neighbor["render"])]
    old_shots = {row["film"]["shot"]["id"]: row for row in (previous or {}).get("shots", [])}
    rows = []
    for declaration, specification in pairs:
        old = old_shots.get(declaration["shot"]["id"])
        if old:
            declaration["shot"]["revision"] = old["film"]["shot"]["revision"]
            if declaration != old["film"] or specification != old["render"]:
                declaration["shot"]["revision"] += 1
        rows.append(dict(film=declaration, render=deepcopy(specification), clip_id=None, output_binding=None, anchors=[], output_review=None))
    durations = [row["render"]["params"].get("duration") for row in rows]
    explicit_duration = all(isinstance(value, (int, float)) and not isinstance(value, bool)
                            and math.isfinite(value) and value > 0 for value in durations)
    cues = [dict(id="continuous-room", shot_ids=[row["film"]["shot"]["id"] for row in rows],
                 layer="environment", purpose="continuous synthetic room tone", at=0, duration=sum(durations))] if explicit_duration else []
    return dict(story="Original synthetic three-shot continuity smoke", shots=rows, sound_cues=cues)


def author(session, project, film, prepared_render):
    before = session.call("get_timeline", {"project": project}).get("production")
    old_plan = before.get("plan") if before else None
    plan = full_plan(film, prepared_render, old_plan)
    saved = session.call("save_project", dict(project=project, expected_revision=before["revision"] if before else 0,
                                               production=plan))
    current = session.call("get_timeline", {"project": project})["production"]
    assert current["plan"]["shots"][1]["film"] == plan["shots"][1]["film"]
    assert current["readiness"]["preflight_is_output_review"] is False
    assert all(row["output_observations_current"] is False for row in current["readiness"]["shots"])
    assert all(row["needs_refresh_for_regeneration"] is False for row in current["readiness"]["shots"]), "No-output storyboard bootstrap is allowed"
    # Public canonical optional nulls may be added by the App. Do not infer a new revision from JSON formatting.
    if old_plan == current["plan"]:
        assert current["revision"] == before["revision"], "An unchanged authoring call is a no-op"
    else:
        assert current["revision"] == (before["revision"] if before else 0) + 1
    assert "saved" in saved
    return current["plan"]["shots"][1]["film"]


def assert_atomic_cas(session, project):
    before = session.call("get_timeline", {"project": project})["production"]
    result, error = session.mcp.call("save_project", dict(project=project, expected_revision=before["revision"] + 1,
                                                         production=before["plan"]))
    assert error, "A stale expected_revision must fail"
    after = session.call("get_timeline", {"project": project})["production"]
    assert after["revision"] == before["revision"] and after["plan"] == before["plan"], "Validation is atomic"
    return result

"""MCP-only invalidation/undo/rebind checks; old media history must never renew itself."""
from copy import deepcopy

from production_state_support import keyed
from production_state_story import rewire


def snapshots(production):
    return keyed(production["expected_snapshots"]["shots"])


def assert_middle_stale(run, before, after):
    old, new = snapshots(before), snapshots(after)
    ready = keyed(after["readiness"]["shots"])
    assert new["shot-b"]["source_snapshot"] != old["shot-b"]["source_snapshot"]
    assert new["shot-a"]["source_snapshot"] == old["shot-a"]["source_snapshot"]
    assert new["shot-c"]["source_snapshot"] == old["shot-c"]["source_snapshot"]
    assert {"output_binding_changed", "source_review_missing_or_stale", "previous_output_seam_needs_review",
            "next_output_seam_needs_review"} <= set(ready["shot-b"]["findings"])
    assert "source_review_missing_or_stale" not in ready["shot-a"]["findings"]
    assert "source_review_missing_or_stale" not in ready["shot-c"]["findings"]
    assert all(row["needs_realign"] and not row["measured_current"] for row in after["readiness"]["sound_cues"])
    assert ready["shot-b"]["historical_anchors_recorded"] == 2
    assert ready["shot-b"]["input_anchor_current"] is False and ready["shot-b"]["needs_refresh_for_regeneration"]
    assert after["plan"]["shots"][1]["anchors"] == before["plan"]["shots"][1]["anchors"]
    assert after["plan"]["shots"][1]["output_binding"] == before["plan"]["shots"][1]["output_binding"]
    assert after["plan"]["shots"][1]["clip_id"] == before["plan"]["shots"][1]["clip_id"], "Swap/trim replaced UUID"
    run.quote(expect_refusal=True)


def sound_then_trim(run):
    assert run.stage == "baseline_reviewed"
    baseline = run.production()
    run.s.call("set_track", {"project": run.project, "track": "A1", "volume_db": -12})
    changed = run.production()
    assert all(row["needs_realign"] and not row["measured_current"] for row in changed["readiness"]["sound_cues"])
    assert all(row["output_observations_current"] for row in changed["readiness"]["shots"])
    assert snapshots(changed) == snapshots(baseline), "Audio fader invalidated picture-only evidence"
    run.s.call("undo", {"project": run.project, "steps": 1})
    assert run.production() == baseline
    run.case("actual A1 fader invalidates measured mix, keeps picture observations, undo restores exact evidence")
    middle = baseline["plan"]["shots"][1]["clip_id"]
    run.s.call("edit_clip", {"project": run.project, "clip_id": middle, "source_in": 0.25, "source_out": 1.75})
    changed = run.production()
    assert_middle_stale(run, baseline, changed)
    assert run.save(changed["plan"]) == changed, "Roundtrip save silently refreshed changed source evidence"
    run.s.call("undo", {"project": run.project, "steps": 1})
    assert run.production() == baseline, "One undo should restore exact old source/history after no-op save"
    run.case("same UUID trim stales both seams, self input and mix; original source reviews stay current; undo restores", changed)


def swap_and_rebind(run):
    assert run.stage == "baseline_reviewed"
    baseline = run.production()
    middle = baseline["plan"]["shots"][1]["clip_id"]
    # Use this run's actual MCP export as replacement media; no external file editing or extra cloud job.
    run.s.call("edit_clip", {"project": run.project, "clip_id": middle, "file": run.last_mix_file, "source_in": 0.25})
    changed = run.production()
    assert_middle_stale(run, baseline, changed)
    assert run.save(changed["plan"]) == changed
    reopened = run.reopen()
    assert keyed(reopened["readiness"]["shots"])["shot-b"]["needs_refresh_for_regeneration"]
    assert run.save(reopened["plan"]) == reopened
    plan = deepcopy(reopened["plan"])
    expected = snapshots(reopened)["shot-b"]
    wrong = deepcopy(plan)
    wrong["shots"][1]["output_binding"] = expected["source_snapshot"]
    run.refuse_plan(wrong)
    plan["shots"][1]["output_binding"] = expected["output_binding"]
    rebound = run.save(plan)
    ready = keyed(rebound["readiness"]["shots"])["shot-b"]
    assert "output_binding_changed" not in ready["findings"]
    assert "source_review_missing_or_stale" in ready["findings"] and ready["needs_refresh_for_regeneration"]
    assert rebound["plan"]["shots"][1]["anchors"] == baseline["plan"]["shots"][1]["anchors"]
    # Reopening rotates the project scope. Prepare the same historical local PNGs
    # explicitly so refusal below cannot be merely an expired/wrong-project token.
    old = run.production()["plan"]
    base, prepared = run.prepare(run.base["image"], run.base["last_image"])
    plan = deepcopy(old)
    plan["shots"][1]["render"] = {**deepcopy(prepared["prepared_render"]), "context": deepcopy(plan["shots"][1]["film"]["context"])}
    rebound = run.save(rewire(plan, old))
    run.base, run.prepared = base, prepared
    assert rebound["plan"]["shots"][1]["anchors"] == baseline["plan"]["shots"][1]["anchors"], "Explicit request preparation rewrote historical anchors"
    run.quote(expect_refusal=True)
    run.stage = "rebound_pending_review"
    run.case("MCP swap/reopen preserves stale native history; explicit output binding does not renew review", rebound)
    return rebound


def verify_rebound_review(run):
    assert run.stage == "rebound_reviewed"
    state = run.production()
    ready = keyed(state["readiness"]["shots"])["shot-b"]
    assert ready["output_observations_current"] is True
    assert ready["input_anchor_current"] is False and ready["needs_refresh_for_regeneration"] is True
    run.quote(expect_refusal=True)
    run.case("new actual output observations can be current while historical inputs still block regeneration", state)

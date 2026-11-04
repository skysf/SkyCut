"""Prepare actual MCP-native PNG roles and exercise strict author/runtime boundaries."""
from copy import deepcopy
import time

from production_state_story import apply_prepared_anchors


def capture(run):
    from native_anchor_capture import capture_bound_anchor
    label = run.tag + "-" + str(time.time_ns())
    anchors = [capture_bound_anchor(run.s, run.work, source_project=run.project,
                                    from_shot_id="shot-a", role="first", source_edge="last_used", label=label + "-first"),
               capture_bound_anchor(run.s, run.work, source_project=run.project,
                                    from_shot_id="shot-b", role="last", source_edge="last_used", label=label + "-last")]
    base, prepared = run.prepare(anchors[0]["file"], anchors[1]["file"])
    result = apply_prepared_anchors(run, anchors, base, prepared)
    run.anchor_contacts = [file for item in anchors for file in item["contact_sheets"]]
    run.evidence("native-bound-anchors-" + str(time.time_ns()), anchors)
    run.quote()
    run.case("native PNG roles match exact bound used windows and uploaded originals; quote remains preflight", result)
    return anchors


def author_negatives(run, anchors):
    original = run.production()["plan"]
    for field, bad_value in (("source_edge", "first_used"), ("from_shot_id", "shot-c"),
                             ("asset_url", original["shots"][1]["render"]["inputs"]["last_frame_url"])):
        bad = deepcopy(original)
        bad["shots"][1]["anchors"][0][field] = bad_value
        run.refuse_plan(bad)
    # Native source metadata from a different role cannot be called A's last-used anchor.
    bad = deepcopy(original)
    bad["shots"][1]["anchors"][0]["source_frame"] = deepcopy(anchors[1]["source_frame"])
    # The fixture windows share a source file, so source_clip_uuid alone is correctly NOT authority.
    # Use an incompatible edge instead of falsely expecting two identical used windows to differ.
    bad["shots"][1]["anchors"][0]["source_edge"] = "first_used"
    run.refuse_plan(bad)
    run.case("native role, from-shot and asset URL authoring negatives are atomic")


def reference_chain_negative(run, anchors):
    # Save valid native evidence B with the real URL for uploaded A. Authoring cannot prove
    # remote URL byte provenance alone; actual runtime ReferencePlan must reject the mismatch.
    original = run.production()
    old_base, old_prepared = run.base, run.prepared
    base, prepared = run.prepare(anchors[1]["file"], anchors[0]["file"])
    apply_prepared_anchors(run, anchors, base, prepared)
    run.quote(expect_refusal=True)
    run.s.call("undo", {"project": run.project, "steps": 1})
    run.base, run.prepared = old_base, old_prepared
    assert run.production() == original
    run.case("source_frame PNG to actual prepared role file closes the runtime reference chain")


def native_boundary_cases(run):
    from mcp_source_frame_smoke import run as run_native
    evidence = run_native(run.s, run.work)
    # The helper may leave last-opened pointing to its closed scratch; all our calls name project explicitly.
    rejected = [row for row in evidence if row.get("requires_author_refusal")]
    assert len(rejected) == 1 and rejected[0]["source_frame"]["requested_in_used_window"] is False
    plan = deepcopy(run.production()["plan"])
    plan["shots"][1]["anchors"][0]["source_frame"] = deepcopy(rejected[0]["source_frame"])
    refusal = run.refuse_plan(plan)
    run.evidence("native-boundary-author-refusal", dict(native=rejected[0], refusal=refusal))
    run.case("actual MCP save refuses unchanged native quantized-before-use evidence", evidence)
    return evidence

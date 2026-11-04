"""Pure checks for new smoke orchestration only; does not claim actual MCP acceptance."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile

from production_state_review import read_observations
from production_state_story import abstract_plan, rewire
from production_state_support import public

checks = 0


def check(value):
    global checks
    checks += 1
    assert value


render = dict(kind="image_to_video", model="minimax-h3", prompt="Original abstract fixture.",
              params=dict(duration=3, resolution="768p", mode="frames"),
              inputs=dict(image_url="https://assets.skycut-smoke.invalid/originals/local-smoke/first.png",
                          last_frame_url="https://assets.skycut-smoke.invalid/originals/local-smoke/last.png"))
plan = abstract_plan(dict(prepared_render=render))
check([row["film"]["shot"]["index"] for row in plan["shots"]] == [0, 1, 2])
check(all(row["film"]["shot"]["actions"] == [] and row["film"]["shot"]["entry"]["hand"] == "none" for row in plan["shots"]))
check(rewire(plan, plan) == plan)
plan["shots"][1]["anchors"] = [{"history": "kept as authored"}]
plan["shots"][1]["output_binding"] = "a" * 64
changed = deepcopy(plan)
changed["shots"][1]["render"]["prompt"] += " Another render request."
result = rewire(changed, plan)
check([row["film"]["shot"]["revision"] for row in result["shots"]] == [2, 2, 2])
check(result["shots"][0]["film"]["next"]["render"] == result["shots"][1]["render"]
      and result["shots"][2]["film"]["previous"]["render"] == result["shots"][1]["render"])
check(result["shots"][1]["anchors"] == plan["shots"][1]["anchors"] and result["shots"][1]["output_binding"] == "a" * 64)
check(public({"quote_token": "not-a-secret", "nested": [{"prepared_references": "not-a-secret", "public": 1}]}) == {"nested": [{"public": 1}]})
manifest = dict(manifest_id="fixture", shots={"shot-a": {"evidence": {"images": ["actual-source.png"]}}},
                seams={"a->b": {"evidence": {"images": ["actual-seam.png"]}}})
review = dict(manifest_id="fixture", reviewer="Actual test reviewer", viewed_images=["actual-source.png", "actual-seam.png"],
              sources={"shot-a": {"notes": "Observed synthetic source."}}, seams={"a->b": {"notes": "Observed synthetic cut."}})
with tempfile.TemporaryDirectory(prefix="skycut-production-driver-check-") as folder:
    path = Path(folder) / "observations.json"
    path.write_text(json.dumps(review))
    check(read_observations(path, manifest) == review)
    for change in [dict(manifest_id="stale"), dict(reviewer=None), dict(viewed_images=["actual-source.png"]),
                   dict(sources={"shot-a": {"notes": None}})]:
        path.write_text(json.dumps({**review, **change}))
        try:
            read_observations(path, manifest)
        except AssertionError:
            check(True)
        else:
            check(False)
print(json.dumps({"pure_driver_checks": checks, "failures": 0, "actual_mcp_executed": False}))

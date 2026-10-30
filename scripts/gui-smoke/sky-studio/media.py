"""真实 App + MCP 的免费多模型 / 多参考 / 拒绝切换冒烟。先运行 run.sh。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
WORK = D / "work"
SERVER = "http://127.0.0.1:18766"
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(tool, args=None):
    value, error = mcp.call(tool, args, timeout=90)
    print(json.dumps(dict(tool=tool, error=error, result=value), ensure_ascii=False), flush=True)
    assert not error, (tool, value)
    return value


def control(**values):
    request = urllib.request.Request(SERVER + "/__control", json.dumps(values).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request))


def log():
    return json.load(urllib.request.urlopen(SERVER + "/__log"))


def submissions(rows):
    return [row["body"] for row in rows if row["method"] == "POST" and row["path"].endswith("/jobs")]


def ledger():
    return call("get_status")["generation"]["spent_today_credits"]


def generate(args, state="done"):
    started = call("generate_media", dict(prompt="a calm blue studio", **args))
    assert started.get("status") == "started", started
    result = mcp.wait_job(started["job_id"], 180)
    print(json.dumps(dict(completed=result), ensure_ascii=False), flush=True)
    assert result["status"] == state, result
    if state == "done":
        file = Path(result["file"])
        if not file.is_absolute():
            file = WORK / file
        subprocess.run([os.environ["SRTFLOW_FFMPEG"], "-v", "error", "-i", str(file), "-f", "null", "-"], check=True)
    return result


try:
    call("open_folder", {"path": str(WORK)})
    call("set_view", {"mode": "background"})
    call("new_project", {"version": "models-" + str(time.time_ns())})
    control(hold=False, quote_error=False, refuse_seedance=False, unknown_submission=False, replacement_expensive=False)
    models = call("get_status", {"models": True, "model": "minimax-h3"})["generation_models"]["models"]
    assert len(models) == 2 and models[0]["inputs"]["modes"]["multimodal"]["max_audio"] == 3
    before = ledger()
    start = len(log())
    assert generate({"kind": "image"})["model_id"] == "nano2"
    assert generate({"kind": "image", "image_context": "asian"})["model_id"] == "seedream5-flash"
    refs = dict(reference_images=["subject.png"], reference_videos=["motion.mp4"], reference_audio=["reference.wav"])
    assert generate(dict(kind="image_to_video", **refs))["model_id"] == "minimax-h3"
    last = submissions(log()[start:])[-1]
    assert [r["type"] for r in last["inputs"]["references"]] == ["image", "video", "audio"]
    assert last["params"]["mode"] == "multimodal" and last["params"]["reference_video_seconds"] == 2
    generate({"kind": "image_to_video", "image": "subject.png", "last_image": "subject.png"})
    assert "last_frame_url" in submissions(log()[start:])[-1]["inputs"]
    assert ledger() == before + 4

    for submit_refusal, refund_polls in [(False, 2), (True, 1)]:
        start, spent = len(log()), ledger()
        control(refuse_seedance=True, submit_refusal=submit_refusal, refund_after_polls=refund_polls)
        done = generate(dict(kind="image_to_video", quality="highest", **refs))
        posted = submissions(log()[start:])
        assert [p["model"] for p in posted] == ["seedance-2-5", "minimax-h3"], posted
        assert posted[0]["inputs"] == posted[1]["inputs"], "replacement must reuse every uploaded reference"
        assert posted[0]["idempotency_key"] != posted[1]["idempotency_key"]
        assert done["model_id"] == "minimax-h3" and len(done["fallback_attempts"]) == 1
        assert ledger() == spent + 1, "original refund plus replacement costs one, not two"

    start, spent = len(log()), ledger()
    control(submit_refusal=True, replacement_expensive=True)
    denied = generate(dict(kind="image_to_video", quality="highest", **refs), state="failed")
    assert len(submissions(log()[start:])) == 1 and "above the approved" in denied["message"]
    assert ledger() == spent
    start = len(log())
    control(refuse_seedance=False, unknown_submission=True, replacement_expensive=False)
    unknown = generate(dict(kind="image_to_video", quality="highest", **refs), state="failed")
    assert len(submissions(log()[start:])) == 1 and unknown["credits_unknown"] is True
    assert not unknown.get("fallback_attempts"), "unknown outcome cannot start another model"
    control(unknown_submission=False, refuse_seedance=False)
    assert all(not row["has_auth"] for row in log() if row["method"] == "PUT" or row["path"].startswith("/files/"))
    (D / "media-results.json").write_text(json.dumps(dict(refund_fallback=done, ceiling=denied, unknown=unknown), indent=2))
    print("PASS actual App/MCP: model discovery, subject defaults, ordered multimodal upload, last frame, refund polling, submit/poll fallback, cost ceiling, unknown outcome and no key leakage")
finally:
    mcp.close()

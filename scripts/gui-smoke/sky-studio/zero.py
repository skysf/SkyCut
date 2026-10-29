"""run.sh 0 后：真实 App 的每日零额度应退本机，克隆失败且没有 /jobs。"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fal"))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(tool, args=None):
    value, error = mcp.call(tool, args)
    assert not error, (tool, value)
    return value


try:
    call("open_folder", {"path": str(D / "work")})
    call("set_view", {"mode": "background"})
    call("new_project", {"version": "zero-" + str(time.time_ns())})
    status = call("get_status")
    assert status["generation"]["daily_limit_credits"] == 0
    args = {"lines": [{"text": "The daily limit fallback is working."}], "voice": "Rachel"}
    started = call("add_voiceover", args)
    narration = mcp.wait_job(started["job_id"], 180)
    assert narration["status"] == "done" and narration["voice"]["quality"] != "Sky Studio voice", narration
    assert "daily limit" in narration["voice"]["note"] and narration["credits_charged"] == 0
    clone = call("add_voiceover", {**args, "clone_from": "reference.wav"})
    refused = mcp.wait_job(clone["job_id"], 60)
    assert refused["status"] == "failed" and "daily limit" in refused["message"], refused
    assert refused["credits_charged"] == 0
    logs = json.load(urllib.request.urlopen("http://127.0.0.1:18766/__log"))
    assert not any(row["path"].endswith("/jobs") for row in logs)
    assert call("get_status")["generation"]["spent_today_credits"] == 0
    (D / "zero-results.json").write_text(json.dumps(dict(narration=narration, clone=refused), ensure_ascii=False, indent=2))
    print("PASS zero daily allowance: native narration fallback, clone refusal, zero paid submissions and zero local spending")
finally:
    mcp.close()

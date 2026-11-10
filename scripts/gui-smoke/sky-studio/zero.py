"""run.sh 0 后：真实 App 的每日硬预算为零：配音当场停（daily_budget_exceeded，回任务号之前），不改成本机音色，没有 /jobs。"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
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
    before_spend = status["generation"]["spent_today_credits"]
    before_logs = json.load(urllib.request.urlopen("http://127.0.0.1:" + os.environ.get("SKYSTUDIO_SMOKE_PORT", "18766") + "/__log"))
    before_jobs = sum(row["path"].endswith("/jobs") for row in before_logs)
    args = {"lines": [{"text": "The daily limit fallback is working."}], "voice": "en_male"}
    narration = call("add_voiceover", args)
    assert narration["status"] == "blocked" and narration["code"] == "daily_budget_exceeded" and "job_id" not in narration, narration
    assert "confirm_token" not in narration and "daily_ai_credit_limit" == narration["settings_field"]
    preset = call("add_voiceover", {**args, "voice": "gemini:Charon"})
    assert preset["status"] == "blocked" and preset["code"] == "daily_budget_exceeded", preset
    logs = json.load(urllib.request.urlopen("http://127.0.0.1:" + os.environ.get("SKYSTUDIO_SMOKE_PORT", "18766") + "/__log"))
    assert sum(row["path"].endswith("/jobs") for row in logs) == before_jobs
    assert call("get_status")["generation"]["spent_today_credits"] == before_spend
    (D / "zero-results.json").write_text(json.dumps(dict(narration=narration, preset=preset), ensure_ascii=False, indent=2))
    print("PASS zero daily allowance: narration paused before job_id without a voice change, zero paid submissions and zero local spending")
finally:
    mcp.close()

"""真实 App/MCP 的免费配音冒烟；先运行同目录 run.sh。结果保留在测试目录。
2026-11-10（声音 PR 3）：不点名用 gemini:Charon、整段报价一次再回 job_id、每批带同一个 params.plan；Gemini 不报字的时间，字幕靠这台 Mac 转写
（要 macOS 26 和英文的转写模型）；clone_from 去掉了（声音库的克隆是声音 PR 6）；报价时服务器不答就当场用本机的声音、不起任务。"""
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
    print(json.dumps({"tool": tool, "error": error, "result": value}, ensure_ascii=False), flush=True)
    assert not error, (tool, value)
    return value


def control(**values):
    request = urllib.request.Request(SERVER + "/__control", json.dumps(values).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request))


def ledger():
    return call("get_status")["generation"]["spent_today_credits"]


def job(started):
    assert started.get("status") == "started" and started.get("job_id"), started
    result = mcp.wait_job(started["job_id"], 180)
    print(json.dumps({"job": result}, ensure_ascii=False), flush=True)
    assert result["status"] == "done", result
    return result


def new_project():
    return call("new_project", {"version": str(time.time_ns())})["project"]


try:
    log_start = len(json.load(urllib.request.urlopen(SERVER + "/__log")))
    call("get_status")
    assert {"generate_media", "upscale_clip"}.issubset(mcp.tools()), "Sky Studio key must synchronize the paid-tool marker at startup"
    call("open_folder", {"path": str(WORK)})
    call("set_view", {"mode": "background"})
    new_project()
    before = ledger()
    lines = [{"text": "Hello world, this is the first line."}, {"text": "Hello world, this is the first line."}]
    started = call("add_voiceover", {"lines": lines, "subtitles": True})
    assert started["voice"]["name"] == "gemini:Charon" and started["voice_plan"]["selection"]["model"] == "gemini-3.8-flash-tts", started
    narration = job(started)
    assert len(narration["added"]) == 2 and narration["subtitles"]["added"] >= 2, narration
    assert narration["voice"]["quality"] == "Sky Studio voice" and narration["voice"]["name"] == "gemini:Charon"
    assert len(narration["skystudio_job_ids"]) == 2
    assert ledger() == before + 2
    call("get_timeline")
    call("get_subtitles")
    call("undo")
    after_undo = call("get_timeline")
    assert not any(t.get("clips") for t in after_undo.get("tracks", [])), after_undo
    # clone_from 去掉了：说明上没有的参数名，整个调用不做。
    refused, error = mcp.call("add_voiceover", {"lines": lines, "clone_from": "voice-sample.wav"}, timeout=90)
    assert error and "clone_from" in json.dumps(refused), refused
    # queued 取消退款，重复取消也不重复退款。
    new_project()
    control(hold=True)
    started = call("add_voiceover", {"lines": [{"text": "A queued cancellation test."}]})
    for _ in range(60):
        progress = call("get_job", {"job_id": started["job_id"]})
        if progress.get("skystudio_job_id"):
            break
        time.sleep(0.1)
    assert progress.get("skystudio_job_id"), progress
    call("cancel_job", {"job_id": started["job_id"]})
    cancelled = mcp.wait_job(started["job_id"], 30)
    assert cancelled["status"] == "cancelled", cancelled
    call("cancel_job", {"job_id": started["job_id"]})
    assert ledger() == before + 2
    control(hold=False, quote_error=True)
    new_project()
    fallback = call("add_voiceover", {"lines": [{"text": "The local fallback is working."}]})
    assert "job_id" not in fallback and fallback["voice"]["quality"] != "Sky Studio voice" and fallback["voice"].get("note"), fallback
    assert ledger() == before + 2
    logs = json.load(urllib.request.urlopen(SERVER + "/__log"))[log_start:]
    submits = [row for row in logs if row["method"] == "POST" and row["path"].endswith("/jobs")]
    assert len(submits) == 3, submits
    assert len({row["body"]["idempotency_key"] for row in submits}) == 3
    assert all(row["body"]["model"] == "auto" and row["body"]["params"]["plan"]["voice"] == "gemini:Charon" for row in submits), submits
    quotes = [row for row in logs if row["method"] == "POST" and row["path"].endswith("/quote") and row["body"]["kind"] == "voice"]
    assert all("batches" in row["body"]["params"] and "prompt" not in row["body"] for row in quotes), quotes
    assert all(not row["has_auth"] for row in logs if row["method"] == "PUT" or row["path"].startswith("/files/"))
    for done in [narration, fallback]:
        for added in done["added"]:
            file = Path(added["file"])
            if not file.is_absolute():
                file = WORK / file
            subprocess.run([os.environ["SRTFLOW_FFMPEG"], "-v", "error", "-i", str(file), "-f", "null", "-"], check=True)
    (D / "voice-results.json").write_text(json.dumps(dict(narration=narration, fallback=fallback, cancelled=cancelled), ensure_ascii=False, indent=2))
    print("PASS actual App: gemini:Charon by default, whole-segment quote, one selection per batch, subtitles by local transcription, one undo, "
          "clone_from refused, queued cancellation/refund, native fallback before paying, file decode, no duplicate POSTs or key leakage")
finally:
    mcp.close()

"""真实 App/MCP 的免费配音冒烟；先运行同目录 run.sh。结果保留在测试目录。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fal"))
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
    call("open_folder", {"path": str(WORK)})
    call("set_view", {"mode": "background"})
    new_project()
    before = ledger()
    lines = [{"text": "Hello world, this is the first line."}, {"text": "Hello world, this is the first line."}]
    narration = job(call("add_voiceover", {"lines": lines, "subtitles": True}))
    assert len(narration["added"]) == 2 and narration["subtitles"]["added"] >= 2, narration
    assert narration["voice"]["quality"] == "Sky Studio voice"
    assert len(narration["skystudio_job_ids"]) == 2
    assert ledger() == before + 2
    call("get_timeline")
    call("get_subtitles")
    call("undo")
    after_undo = call("get_timeline")
    assert not any(t.get("clips") for t in after_undo.get("tracks", [])), after_undo
    # 两句克隆共享一单；真实转写 → 句界 → 两个文件与字幕 → 一步撤销。
    new_project()
    cloned = job(call("add_voiceover", {"lines": lines, "clone_from": "reference.wav", "subtitles": True}))
    assert len(cloned["added"]) == 2 and len(cloned["skystudio_job_ids"]) == 1, cloned
    assert cloned["subtitles"]["added"] >= 2
    assert ledger() == before + 4.5
    call("undo")
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
    assert ledger() == before + 4.5
    control(hold=False, quote_error=True)
    new_project()
    fallback = job(call("add_voiceover", {"lines": [{"text": "The local fallback is working."}]}))
    assert fallback["voice"]["quality"] != "Sky Studio voice" and fallback["voice"].get("note"), fallback
    assert ledger() == before + 4.5
    logs = json.load(urllib.request.urlopen(SERVER + "/__log"))[log_start:]
    submits = [row for row in logs if row["method"] == "POST" and row["path"].endswith("/jobs")]
    assert len(submits) == 4, submits
    assert len({row["body"]["idempotency_key"] for row in submits}) == 4
    clones = [row for row in submits if row["body"]["kind"] == "voice_clone"]
    assert len(clones) == 1 and "\n" in clones[0]["body"]["prompt"]
    assert all(not row["has_auth"] for row in logs if row["method"] == "PUT" or row["path"].startswith("/files/"))
    for done in [narration, cloned, fallback]:
        for added in done["added"]:
            file = Path(added["file"])
            if not file.is_absolute():
                file = WORK / file
            subprocess.run([os.environ["SRTFLOW_FFMPEG"], "-v", "error", "-i", str(file), "-f", "null", "-"], check=True)
    (D / "voice-results.json").write_text(json.dumps(dict(narration=narration, clone=cloned, fallback=fallback, cancelled=cancelled), ensure_ascii=False, indent=2))
    print("PASS actual App: cloud narration, batched clone, subtitles, one undo, queued cancellation/refund, native fallback, file decode, no duplicate POSTs or key leakage")
finally:
    mcp.close()

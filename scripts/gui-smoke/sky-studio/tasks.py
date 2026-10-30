"""摆出四个排队任务供 GUI 验证：只连 run.sh 的独立假服务，预计合计 640 积分。"""
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
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"),
          env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(tool, args=None):
    result, error = mcp.call(tool, args)
    print(json.dumps(dict(tool=tool, error=error, result=result), ensure_ascii=False), flush=True)
    assert not error, (tool, result)
    return result


try:
    quotes = {f"cloud task {i:02}": credits for i, credits in enumerate([240, 112, 112, 176], 1)}
    request = urllib.request.Request("http://127.0.0.1:18766/__control",
        json.dumps(dict(hold=True, quotes_by_prompt=quotes, cancel_already_started=False)).encode(),
        {"Content-Type": "application/json"})
    with urllib.request.urlopen(request) as response:
        assert response.status == 200
    call("open_folder", {"path": str(D / "work")})
    call("new_project", {"version": "tasks-" + str(time.time_ns())})
    call("set_view", {"mode": "visible"})
    call("add_clips", {"clips": [{"file": "motion.mp4"}]})
    jobs = []
    for index in range(1, 5):
        result = call("generate_media", {"kind": "text_to_video", "model": "minimax-h3",
            "prompt": f"cloud task {index:02}", "name": f"视频 {index:02}"})
        assert result["status"] == "started"
        jobs.append(result["job_id"])
    (D / "task-ui-jobs.json").write_text(json.dumps(jobs))
    print("READY: four queued tasks; open the toolbar task popover and verify 640 estimated credits.")
finally:
    mcp.close()

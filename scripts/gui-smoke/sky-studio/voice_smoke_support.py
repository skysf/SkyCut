"""声音冒烟（voice_library.py、voice_concurrency.py）共用的那几样：连 run.sh 起的测试 App 的小程序、调用并打印、读写假服务的控制项和日志。
只连 run.sh 的独立测试身份（SKYSTUDIO_SMOKE_DIR / SKYSTUDIO_SMOKE_PORT），只有假 Key、回环假服务，不碰生产钱包和用户的工程。"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP  # noqa: E402

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
WORK = D / "work"
SERVER = "http://127.0.0.1:" + os.environ.get("SKYSTUDIO_SMOKE_PORT", "18766")


class Smoke:
    def __init__(self):
        self.mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})

    def close(self):
        self.mcp.close()

    def call(self, tool, args=None, timeout=90):
        value, error = self.mcp.call(tool, args, timeout=timeout)
        print(json.dumps({"tool": tool, "args": args, "error": error, "result": value}, ensure_ascii=False)[:4000], flush=True)
        assert not error, (tool, value)
        return value

    def refused(self, tool, args):
        """要它报错的调用：回报错的话（文字），一并打印。"""
        value, error = self.mcp.call(tool, args, timeout=90)
        print(json.dumps({"tool": tool, "args": args, "error": error, "result": value}, ensure_ascii=False)[:2000], flush=True)
        assert error, (tool, "should have been refused", value)
        return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)

    def wait(self, job_id, seconds=180):
        result = self.mcp.wait_job(job_id, seconds)
        print(json.dumps({"job": result}, ensure_ascii=False)[:4000], flush=True)
        return result

    def settings(self, values):
        """set_settings：要用户点头的改动，这里扮演测试用户点头（正式会话必须等用户真的答复）。"""
        result = self.call("set_settings", values)
        if result.get("status") == "needs_confirmation":
            result = self.call("set_settings", {**values, "confirm_token": result["confirm_token"]})
        return result

    def spent(self):
        return self.call("get_status")["generation"]["spent_today_credits"]

    def timeline_counts(self, project):
        timeline = self.call("get_timeline", {"project": project})
        clips = sum(len(track.get("clips") or []) for track in timeline.get("tracks", []))
        cues = self.call("get_subtitles", {"project": project})
        return clips, cues["original"]["total"]


def control(**values):
    request = urllib.request.Request(SERVER + "/__control", json.dumps(values).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def release(count=None, kind=None):
    body = {key: value for key, value in (("count", count), ("kind", kind)) if value is not None}
    request = urllib.request.Request(SERVER + "/__release", json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def server(path):
    with urllib.request.urlopen(SERVER + path, timeout=5) as response:
        return json.load(response)


def log():
    return server("/__log")


def rows(entries, method, part, **body):
    """日志里某一种请求（路径里含 `part`），可以再按请求体的几个字段筛。"""
    picked = [row for row in entries if row["method"] == method and part in row["path"]]
    return [row for row in picked if all((row.get("body") or {}).get(k) == v for k, v in body.items())]


def wait_until(check, seconds=30, step=0.2):
    end = time.time() + seconds
    while time.time() < end:
        value = check()
        if value:
            return value
        time.sleep(step)
    raise AssertionError("condition not reached in %ss" % seconds)

"""官方 MCP 冒烟的隔离会话与证据；只驱动测试 App，不在进程外编辑或分析成片。"""
import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
WORK = D / "work"
APP = D / "SrtFlowSkyStudioSmoke.app"
SERVER = "http://127.0.0.1:18766"


def control(**value):
    request = urllib.request.Request(SERVER + "/__control", json.dumps(value).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def log():
    with urllib.request.urlopen(SERVER + "/__log", timeout=5) as response:
        return json.load(response)


def posts(rows, route="jobs"):
    return [row["body"] for row in rows if row["method"] == "POST" and row["path"].endswith("/" + route)]


def admitted():
    with urllib.request.urlopen(SERVER + "/__state", timeout=5) as response:
        return json.load(response)["admitted_jobs"]


class Session:
    def __init__(self):
        self.mcp = MCP(str(APP / "Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
        self.evidence = D / ("official-evidence-" + str(time.time_ns()))
        self.evidence.mkdir()
        self.passed = []

    def call(self, name, args=None):
        value, error = self.mcp.call(name, args, timeout=90)
        assert not error, (name, value)
        assert "recipe_pin" not in json.dumps(value), "Opaque pin leaked into MCP result"
        return value

    def refused(self, args):
        before, mark = self.spent(), len(log())
        value, error = self.mcp.call("generate_media", args, timeout=90)
        assert error or value.get("status") in ("blocked", "needs_confirmation"), value
        assert not posts(log()[mark:]) and self.spent() == before, "Rejected request performed paid work"
        return value

    def wait(self, job, expected="done"):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            value = self.call("get_job", {"job_id": job, "wait_seconds": 10})
            if value["status"] in ("done", "failed", "cancelled"):
                assert value["status"] == expected, value
                return value
        raise TimeoutError("Official fixture job did not reach a terminal status")

    def spent(self):
        return self.call("get_status")["generation"]["spent_today_credits"]

    def passed_case(self, label):
        self.passed.append(label)
        print("PASS " + label, flush=True)

    def background(self, project):
        owned = next(item for item in self.call("get_status")["projects"] if item["id"] == project)
        assert owned["yours"] and owned["view"] == "background" and owned["shown_in"] == "background (no window)", owned

    def ownership(self, project):
        other = MCP(str(APP / "Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
        try:
            _, error = other.call("get_timeline", {"project": project}, timeout=30)
            assert error, "Another MCP helper must not claim this active project"
        finally:
            other.close()

    def look(self, args, label):
        result = self.mcp.request("tools/call", {"name": "look", "arguments": args}, timeout=90)["result"]
        assert not result.get("isError"), result
        content = result["content"]
        value = json.loads(next(item["text"] for item in content if item["type"] == "text"))
        images = [item for item in content if item["type"] == "image"]
        assert images and value["frames"], "MCP look must return its actual contact sheet"
        assert all(frame.get("brightness", 0) > 0.05 for frame in value["frames"]), value
        for index, item in enumerate(images):
            suffix = ".png" if item["mimeType"] == "image/png" else ".jpg"
            (self.evidence / (label + "-" + str(index) + suffix)).write_bytes(base64.b64decode(item["data"], validate=True))
        (self.evidence / (label + ".json")).write_text(json.dumps(value, indent=2))
        return value

    def restart(self, key_letter="S"):
        # 只重启完整路径匹配的这一份测试 App；保留假服务与回执，不碰正常 App。
        status = self.call("get_status")
        assert not status.get("jobs"), "Wait for owned jobs before restarting"
        for project in status["projects"]:
            if project.get("yours"):
                self.call("save_project", {"project": project["id"]})
        executable = str(APP / "Contents/MacOS/SrtFlowSkyStudioSmoke")
        processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
        matches = [int(row.strip().split(None, 1)[0]) for row in processes.splitlines()
                   if row.strip().split(None, 1)[-1].split(" ", 1)[0] == executable]
        assert len(matches) == 1, "Cannot identify exactly one isolated smoke App"
        self.mcp.close()
        os.kill(matches[0], signal.SIGTERM)
        deadline = time.monotonic() + 15
        while subprocess.run(["kill", "-0", str(matches[0])], capture_output=True).returncode == 0:
            assert time.monotonic() < deadline, "Isolated App did not exit"
            time.sleep(0.1)
        ffmpeg = os.environ.get("SRTFLOW_FFMPEG", str(Path(__file__).resolve().parents[3] / "vendor/ffmpeg"))
        args = ["open", "-g", "-n"]
        for value in ["SRTFLOW_SKYSTUDIO_API_BASE=" + SERVER + "/api/skycut/v1",
                      "SRTFLOW_SMOKE_CACHE_DIR=" + str(D / "optimized-media"),
                      "SRTFLOW_SMOKE_SKYSTUDIO_KEY=sk-" + key_letter * 43,
                      "SRTFLOW_FFMPEG=" + ffmpeg, "SRTFLOW_SMOKE_MUTE=1"]:
            args.extend(["--env", value])
        launched_at = time.time_ns()
        subprocess.run(args + [str(APP)], check=True, timeout=10)
        socket = Path.home() / "Library/Application Support/com.srtflow.SrtFlow.skystudiosmoke/mcp.sock"
        deadline = time.monotonic() + 20
        while not socket.is_socket() or socket.stat().st_mtime_ns < launched_at:
            assert time.monotonic() < deadline, "Restarted test App did not expose MCP"
            time.sleep(0.2)
        self.mcp = MCP(str(APP / "Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
        self.call("open_folder", {"path": str(WORK)})
        self.call("set_view", {"mode": "background"})

    def close(self):
        self.mcp.close()

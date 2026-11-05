"""独立真 App 的主题回归：单个 MCP 会话持有两个工程，颜色切换不改时间线。"""
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
HELPER = D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"


def run():
    mcp = MCP(str(HELPER), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
    try:
        def call(name, args=None):
            data, error = mcp.call(name, args, timeout=35)
            assert not error, (name, data)
            return data

        call("open_folder", {"path": str(D / "work")})
        # 每条都给绝对素材路径；每个工程都给 version，同一会话始终持有两者。
        # 重连后旧会话的保护租约还在，不能拿旧会话的 id 继续写。
        first = call("new_project", {"name": "Theme", "version": "primary", "folder": str(D / "work")})["project"]
        call("add_clips", {"project": first, "clips": [
            {"file": str(D / "work/motion.mp4"), "track": "V1"} for _ in range(8)
        ] + [{"file": str(D / "work/reference.wav"), "track": "A1"}]})
        call("set_text", {"project": first, "text": "Theme verification", "start": 0, "duration": 8})
        second = call("new_project", {"name": "Theme", "version": "comparison", "folder": str(D / "work")})["project"]
        call("add_clips", {"project": second, "clips": [
            {"file": str(D / "work/subject.png"), "track": "V1", "source_out": 8}
        ]})
        call("seek", {"project": first, "time": 1.25})
        projects = [first, second]
        # 先让导入后的媒体重建、时钟回调落稳，再开始比较；超时不能冒充通过。
        before = {p: call("get_timeline", {"project": p}) for p in projects}
        deadline, stable_since = time.monotonic() + 20, time.monotonic()
        while time.monotonic() - stable_since < 1:
            assert time.monotonic() < deadline, "Imported project did not settle"
            time.sleep(0.2)
            current = {p: call("get_timeline", {"project": p}) for p in projects}
            if current != before:
                before, stable_since = current, time.monotonic()
        for theme in ["classic", "forest", "classic", "forest"]:
            changed = call("set_settings", {"theme": theme})
            assert changed["sections"]["general"]["theme"] == theme
            for project in projects:
                after = call("get_timeline", {"project": project})
                if after != before[project]:
                    mismatch = D / "theme-timeline-mismatch.json"
                    mismatch.write_text(json.dumps({"before": before[project], "after": after}, indent=2))
                    raise AssertionError(("Theme changed timeline", project, theme, str(mismatch)))
        call("set_view", {"project": first, "mode": "visible"})
        report = {"result": "passed", "projects": projects, "theme_switches": 4,
                  "timelines_content_colors_ids_and_geometry_unchanged": True}
        (D / "themes-report.json").write_text(json.dumps(report, indent=2))
        print("PASS: four theme switches preserve two populated projects, content colors, IDs and geometry.")
    finally:
        mcp.close()


if __name__ == "__main__":
    run()

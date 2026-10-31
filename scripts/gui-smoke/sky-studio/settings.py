"""统一设置的端到端冒烟：真 App / 真小程序 / 独立测试域，不清理生产缓存或写客户端配置。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
DOMAIN = "com.srtflow.SrtFlow.skystudiosmoke"
HELPER = D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"


def preferences(settings):
    sections = settings["sections"]
    return (sections["general"]["language"], sections["cache"]["optimized_media_cache_gb"],
            sections["sky_studio"]["daily_ai_credit_limit"])


def run():
    mcp = MCP(str(HELPER), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
    try:
        def call(name, arguments=None):
            data, error = mcp.call(name, arguments, timeout=35)
            assert not error, (name, data)
            return data

        status = call("get_status")
        assert status["skycut_plan"]["ai_tools"], "Start the isolated Sky Studio smoke App first"
        before_projects = [p["id"] for p in status["projects"]]
        catalog = mcp.request("tools/list")["result"]["tools"]
        tools = {tool["name"]: tool for tool in catalog}
        assert tools["get_settings"]["annotations"]["readOnlyHint"]
        assert not tools["set_settings"]["annotations"]["readOnlyHint"]
        for name in ("get_settings", "set_settings"):
            assert name in mcp.init["result"]["instructions"]
            assert "project" not in tools[name]["inputSchema"]["properties"]

        initial = call("get_settings")
        assert initial["scope"] == "app"
        assert set(initial["sections"]) == {"general", "ai", "editing", "cache", "sky_studio"}
        schema = tools["set_settings"]["inputSchema"]["properties"]
        assert set(schema["language"]["enum"]) == {
            x["id"] for x in initial["sections"]["general"]["available_languages"]}
        assert schema["optimized_media_cache_gb"]["enum"] == initial["sections"]["cache"]["available_cache_gb"]
        for section in initial["sections"]:
            result = call("get_settings", {"section": section})
            assert list(result["sections"]) == [section]
        assert "sk-SSSS" not in json.dumps(initial), "Never expose even the fake API key"
        assert initial["sections"]["sky_studio"]["api_key_configured"]
        assert "recipes" in initial["sections"]["editing"]["styles"]
        assert "add_voiceover" in initial["sections"]["editing"]["voice_actions"]

        unchanged = preferences(call("get_settings"))
        invalid = [
            {"language": "es", "daily_ai_credit_limit": -1},
            {"language": "es", "daily_ai_credit_limit": 1_000_001},
            {"language": "es", "daily_ai_credit_limit": 1.5},
            {"language": "es", "daily_ai_credit_limit": "nan"},
            {"language": "es", "optimized_media_cache_gb": 3},
            {"language": "es", "clear_optimized_media_cache": []},
            {"language": "unknown", "daily_ai_credit_limit": 7},
            {"language": "es", "api_key": "not-accepted"},
            {}, {"language": None, "clear_optimized_media_cache": False},
        ]
        for args in invalid:
            _, error = mcp.call("set_settings", args, timeout=35)
            assert error, ("Invalid settings must fail", args)
            assert preferences(call("get_settings")) == unchanged, ("Partial update", args)

        for language, cap, limit in [("es", 5, 0), ("en", 20, 1_000_000), ("zh-Hans", 10, 750)]:
            changed = call("set_settings", {"language": language, "optimized_media_cache_gb": cap,
                                            "daily_ai_credit_limit": limit})
            assert preferences(changed) == (language, cap, limit)
            assert preferences(call("get_settings")) == (language, cap, limit)
        # 只写一个字段，其余不变；null 与省略一致。
        result = call("set_settings", {"language": None, "daily_ai_credit_limit": "751"})
        assert preferences(result) == ("zh-Hans", 10, 751)

        # 真实清空路径只碰此轮测试缓存；启动钩子必须先隔离，再开放 MCP 监听。
        cache_dir = D / "optimized-media"
        cache_dir.mkdir(parents=True, exist_ok=True)
        sentinel = cache_dir / "disposable-smoke-sentinel"
        sentinel.write_text("Disposable test cache")
        call("set_settings", {"clear_optimized_media_cache": True})
        deadline = time.monotonic() + 10
        while call("get_settings", {"section": "cache"})["sections"]["cache"]["clearing"]:
            assert time.monotonic() < deadline, "Cache clearing did not finish"
            time.sleep(0.1)
        assert not sentinel.exists(), "App did not clear the isolated test cache"
        assert (D / "work/motion.mp4").is_file(), "Cache clearing must retain source files"

        expected = {"appLanguage": "zh-Hans", "optimizedMedia.capacityBytes": 10_000_000_000,
                    "SrtFlow.skystudio.dailyCreditLimit": 751}
        for key, value in expected.items():
            saved = subprocess.check_output(["defaults", "read", DOMAIN, key], text=True).strip()
            assert saved == str(value), ("Not persisted", key, saved)
        after = call("get_status")
        assert [p["id"] for p in after["projects"]] == before_projects
        # 未命名工程的显示名会随界面语言翻译；身份、内容和存盘状态不得变化。
        assert {k: v for k, v in after["project"].items() if k != "name"} == {
            k: v for k, v in status["project"].items() if k != "name"}, "Settings must not change the project"
        assert after["jobs"] == status["jobs"], "Settings must not start editing or paid jobs"
        report = {"result": "passed", "invalid_atomic_updates": len(invalid),
                  "settings": call("get_settings"), "project_count": len(before_projects)}
        (D / "settings-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print("PASS: tool discovery; five sections; schema/store agreement; 10 atomic refusals; language/cache/budget writes; isolated cache clear; persistence; no project/job changes; no keys returned.")
    finally:
        mcp.close()


if __name__ == "__main__":
    run()

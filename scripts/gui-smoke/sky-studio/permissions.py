"""真 MCP / 真 App / 本地假服务：不花积分验证草稿、审批与硬预算。"""
import json
import os
from pathlib import Path
import sys
import urllib.request

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

        def settings(args):
            result = call("set_settings", args)
            if result.get("status") == "needs_confirmation":
                # 模拟测试用户明确同意；正式会话必须等用户真实答复。
                result = call("set_settings", {**args, "confirm_token": result["confirm_token"]})
            return result

        def jobs():
            with urllib.request.urlopen("http://127.0.0.1:" + os.environ.get("SKYSTUDIO_SMOKE_PORT", "18766") + "/__log", timeout=5) as response:
                return [x for x in json.load(response) if x.get("method") == "POST" and x.get("path", "").endswith("/jobs")]

        initial = call("get_settings")
        mode = initial["sections"]["ai"]["ai_access_mode"]
        limit = initial["sections"]["sky_studio"]["daily_ai_credit_limit"]
        settings({"ai_access_mode": "ask_for_approval", "daily_ai_credit_limit": 1_000})
        project = call("new_project", {"folder": str(D / "work"), "name": "Permission smoke", "version": "isolated"})["project"]
        base = {"project": project, "kind": "image", "model": "nano2", "prompt": "A calm blue studio", "name": "approval fixture"}
        before = len(jobs())
        spent = call("get_settings")["sections"]["sky_studio"]["spent_today"]
        draft = call("generate_media", {**base, "quote_only": True})
        assert draft["status"] == "quoted" and draft["params"]["resolution"] == "1K", draft
        assert draft["charged"] is False
        assert len(jobs()) == before
        assert call("get_settings")["sections"]["sky_studio"]["spent_today"] == spent
        premium = {**base, "resolution": "4K", "idempotency_key": "permission-once-fixture"}
        ask = call("generate_media", premium)
        assert ask["status"] == "needs_confirmation", ask
        assert len(jobs()) == before, "Approval questions cannot submit paid jobs"
        wrong = call("generate_media", {**premium, "prompt": "Different shot", "confirm_token": ask["confirm_token"]})
        assert wrong["status"] == "needs_confirmation" and wrong.get("confirm_token_refused"), wrong
        assert len(jobs()) == before
        started = call("generate_media", {**premium, "confirm_token": ask["confirm_token"]})
        assert started["status"] == "started", started
        done = mcp.wait_job(started["job_id"], 180)
        assert done["status"] == "done", done
        assert len(jobs()) == before + 1, "Only the approved original operation is submitted"
        again = call("generate_media", {**premium, "confirm_token": ask["confirm_token"]})
        assert again["job_id"] == started["job_id"] and len(jobs()) == before + 1
        outside = D / "unopened-permission-fixture" / "script.txt"
        outside.parent.mkdir(parents=True, exist_ok=True)
        outside.write_text("Disposable permission-mode fixture.")
        read_args = {"project": project, "file": str(outside)}
        assert call("read_document", read_args)["status"] == "needs_confirmation"
        settings({"ai_access_mode": "full_access"})
        assert "Disposable permission-mode fixture" in call("read_document", read_args)["text"]
        settings({"daily_ai_credit_limit": 0})
        blocked = call("generate_media", {**base, "resolution": "4K", "user_requested_overrides": True})
        assert blocked["status"] == "blocked" and blocked["code"] == "daily_budget_exceeded", blocked
        assert "confirm_token" not in blocked and len(jobs()) == before + 1
        quoted = call("generate_media", {**base, "quote_only": True})
        assert quoted["status"] == "quoted", "Free quotes remain available at a zero paid budget"
        settings({"daily_ai_credit_limit": 1_000})
        full = call("generate_media", {**base, "resolution": "4K", "idempotency_key": "permission-full-fixture"})
        assert full["status"] == "started" and full["ai_access_mode"] == "full_access", full
        assert full.get("notification")
        assert mcp.wait_job(full["job_id"], 180)["status"] == "done"
        assert len(jobs()) == before + 2
        settings({"ai_access_mode": "ask_for_approval", "daily_ai_credit_limit": limit})
        assert call("read_document", read_args)["status"] == "needs_confirmation", "Full access must not persist a read grant"
        outside.unlink()
        settings({"ai_access_mode": mode})
        call("close_project", {"project": project})
        report = {"result": "passed", "draft_resolution": draft["params"]["resolution"], "fake_generations": 2,
                  "quote_only_does_not_charge": True, "wrong_token_atomic": True, "idempotency_preserved": True,
                  "full_access_hard_budget": True, "real_provider_calls": 0}
        (D / "permissions-report.json").write_text(json.dumps(report, indent=2))
        print("PASS: 1K draft; free quote; exact approval; wrong-token rejection; submit-once; full-access notice; hard budget; no real provider calls.")
    finally:
        mcp.close()


if __name__ == "__main__":
    run()

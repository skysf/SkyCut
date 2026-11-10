"""真 MCP / 真 App / 本地假服务：全部权限下的长期授权（声音 PR 7，SkyCut 声音方案 5.6）。不花积分。

用法（先 run.sh 起独立测试 App 和假 Sky Studio）：
  python3 scripts/gui-smoke/sky-studio/voice_consent.py             # set_settings 打开先问（价目 + 那句）、点头记上、关掉撤掉
  SRTFLOW_SMOKE_ACCESS_MODE=full_access scripts/gui-smoke/sky-studio/run.sh
  python3 scripts/gui-smoke/sky-studio/voice_consent.py migrated    # 升级前就开着全部权限：读到假 Key 时自己记上，不问
设置窗口里那张说明（选全部权限先弹、取消不改）是人工回归，见 docs/architecture/voice-library.md 第八节。"""
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
HELPER = D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"
STANDING = "voice-standing-consent-v1"


def grants(method):
    with urllib.request.urlopen("http://127.0.0.1:18766/__log", timeout=5) as response:
        return [x for x in json.load(response) if x.get("method") == method and x.get("path", "").endswith("/voices/consent-grant")]


def run(mode):
    mcp = MCP(str(HELPER), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})
    try:
        def call(name, args=None):
            data, error = mcp.call(name, args, timeout=35)
            assert not error, (name, data)
            return data

        if mode == "migrated":
            # 起之前就写好了全部权限：App 读到 Key 时应当自己记上（不问），等它一会儿。
            for _ in range(40):
                if grants("POST"):
                    break
                time.sleep(0.5)
            posted = grants("POST")
            assert len(posted) == 1 and posted[0]["body"]["statement_version"] == STANDING, posted
            ai = call("get_settings", {"section": "ai"})["sections"]["ai"]
            assert ai["ai_access_mode"] == "full_access" and ai["voice_standing_consent"]["status"] == "recorded", ai
            print("ok: Full access on before the upgrade records the standing voice consent at launch, without asking")
            return

        before = call("get_settings", {"section": "ai"})["sections"]["ai"]["ai_access_mode"]
        if before != "ask_for_approval":
            asked = call("set_settings", {"ai_access_mode": "ask_for_approval"})
            call("set_settings", {"ai_access_mode": "ask_for_approval", "confirm_token": asked["confirm_token"]})
        posts, deletes = len(grants("POST")), len(grants("DELETE"))
        asked = call("set_settings", {"ai_access_mode": "full_access"})
        question = asked.get("question", "")
        assert asked["status"] == "needs_confirmation", asked
        for phrase in ("751.4", "22.5", "377.6", "For every recording I later use", STANDING, "hard cap"):
            assert phrase in question, (phrase, question)
        assert len(grants("POST")) == posts, "nothing is recorded before the user agrees"
        # 模拟测试用户明确同意；正式会话必须等用户真实答复。
        on = call("set_settings", {"ai_access_mode": "full_access", "confirm_token": asked["confirm_token"]})
        assert on["voice_standing_consent"]["status"] == "recorded", on.get("voice_standing_consent")
        posted = grants("POST")
        assert len(posted) == posts + 1 and posted[-1]["body"]["statement_version"] == STANDING, posted
        assert call("get_settings", {"section": "ai"})["sections"]["ai"]["ai_access_mode"] == "full_access"

        asked = call("set_settings", {"ai_access_mode": "ask_for_approval"})
        assert asked["status"] == "needs_confirmation" and "For every recording" not in asked.get("question", ""), asked
        off = call("set_settings", {"ai_access_mode": "ask_for_approval", "confirm_token": asked["confirm_token"]})
        assert off["voice_standing_consent"]["status"] == "revoked", off.get("voice_standing_consent")
        assert len(grants("DELETE")) == deletes + 1
        print("ok: set_settings asks with the fees and the standing consent, records it on yes and revokes it when turned off")
    finally:
        mcp.close()


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "settings")

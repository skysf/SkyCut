"""冒烟场景二：花钱的把关 —— 超额度 / 价格不明当场回 needs_confirmation + 确认码（2026-10-17 起，AI 多开方案板 9：以前是提示条上问）、
带码再调才记账提交、错的码 / 用过的码不认、额度内不问、停止只停这个工程。
只有「停止」那一步要点按钮（ax.sh 按 accessibilityIdentifier；System Events 看不见测试 App 的窗口时那一步记成「没验到」，不算通过）。
要先 `scripts/gui-smoke/fal/run.sh 0.30`（每日上限 0.30）。见 docs/testing/gui-smoke-testing.md 四之八。"""
import json, os, subprocess, sys, time, urllib.request
sys.dont_write_bytecode = True   # 别在仓库里留 __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcpclient import MCP
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.environ.get("FALSMOKE_DIR", os.path.join(os.environ.get("TMPDIR", "/tmp"), "srtflow-fal-smoke"))
APP = D + "/SrtFlowFalSmoke.app"
fails = 0
skipped = []
def ok(cond, msg, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + msg + (("  -> " + str(extra)[:400]) if (extra and not cond) else ""))
    if not cond: fails += 1
def server_log(): return json.load(urllib.request.urlopen("http://127.0.0.1:18765/__log"))
def posts(prefix): return [e for e in server_log() if e["method"] == "POST" and e["path"].lstrip("/").startswith(prefix)]
def ax(*a): return subprocess.run([HERE + "/ax.sh", *a], capture_output=True, text=True).stdout.strip()

mcp = MCP(APP + "/Contents/Helpers/srtflow-mcp")
windows = subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "SrtFlowFalSmoke" to get count of windows'],
                         capture_output=True, text=True).stdout.strip()
can_click = windows not in ("", "0")
mcp.call("set_view", {"mode": "background"})
mcp.call("open_folder", {"path": D + "/work"})
status, _ = mcp.call("get_status")
ok(status["generation"]["daily_limit_usd"] == 0.3, "the daily limit from settings is $0.30", status.get("generation"))

# 1. 超额度：当场回确认码，什么都不起、不提交、不记账
video = {"kind": "text_to_video", "prompt": "a fox", "name": "ask-video"}
ask, err = mcp.call("generate_media", video)
ok(not err and ask.get("status") == "needs_confirmation" and ask.get("confirm_token"), "video 768p ($0.40, over the $0.30 limit): needs_confirmation with a token", ask)
ok("estimated cost $0.40" in ask.get("question", "") and "$0.30 daily limit" in ask.get("question", ""), "the question has the numbers", ask)
ok("job_id" not in ask and len(posts("minimax/h3-max/text-to-video")) == 0, "no job, nothing sent to fal before the user agrees")
status, _ = mcp.call("get_status")
ok(status["generation"]["spent_today_usd"] == 0 and not status.get("jobs"), "nothing recorded, no job running", status)

# 2. 错的码不认、问同一件事回同一张码
wrong, _ = mcp.call("generate_media", {**video, "confirm_token": "zzzzzz"})
ok(wrong.get("status") == "needs_confirmation" and "not one SrtFlow issued" in wrong.get("confirm_token_refused", ""), "a made-up token is refused with the reason", wrong)
ok(wrong.get("confirm_token") == ask["confirm_token"], "asking again before the user answers returns the same token", wrong)

# 3. 带码再调：才记账、起任务、提交
started, err = mcp.call("generate_media", {**video, "confirm_token": ask["confirm_token"]})
ok(not err and started.get("status") == "started" and started.get("job_id"), "with the token the job starts", started)
job = mcp.wait_job(started["job_id"], 90)
ok(job.get("status") == "done", "the approved video is made", job)
status, _ = mcp.call("get_status")
ok(abs(status["generation"]["spent_today_usd"] - 0.40) < 1e-6, "ledger: $0.40 (recorded when the token was redeemed)", status.get("generation"))
reused, _ = mcp.call("generate_media", {**video, "confirm_token": ask["confirm_token"]})
ok(reused.get("status") == "needs_confirmation" and "already used" in reused.get("confirm_token_refused", ""), "the same token does not work twice", reused)

# 4. 没登记单价的模型：每次都要码；带码之后提交，cancel_job 替 fal 也取消
before = len(posts("acme/whatever"))
unknown = {"kind": "image", "prompt": "x", "model": "acme/whatever"}
ask, _ = mcp.call("generate_media", unknown)
ok(ask.get("status") == "needs_confirmation" and "does not know this model's price" in ask.get("question", ""), "an unknown price needs the user's OK", ask)
started, err = mcp.call("generate_media", {**unknown, "confirm_token": ask["confirm_token"]})
ok(not err and started.get("price_known") is False and started.get("job_id"), "with the token it starts (no estimate)", started)
time.sleep(3)
ok(len(posts("acme/whatever")) == before + 1, "the request is sent to fal")
# 5. 停止（要点横幅上的按钮）：先让主窗口那个工程开一轮（加一行字），再按停止 —— 不碰工程的生成任务记在这个会话最后打开的工程上，跟着停
if can_click:
    mcp.call("set_text", {"text": "stop test", "start": 0, "duration": 2})
    time.sleep(1)
    res = ax("click", "ai-banner-stop")
    ok("clicked" in res, "pressed Stop on the bar", res)
    job = mcp.wait_job(started["job_id"], 30)
    ok(job.get("status") == "cancelled", "Stop cancelled the running generation", job)
    refused, err = mcp.call("get_timeline")
    ok(err and "pressed Stop" in json.dumps(refused), "the next call on that project is told the user pressed Stop", refused)
else:
    skipped.append("Stop on the banner (System Events cannot see the smoke app's windows)")
    mcp.call("cancel_job", {"job_id": started["job_id"]})
    job = mcp.wait_job(started["job_id"], 30)
    ok(job.get("status") == "cancelled", "cancel_job stops the running request", job)
ok(any(e["method"] == "PUT" and "acme/whatever" in e["path"] and e["path"].endswith("/cancel") for e in server_log()), "fal was asked to cancel the request too (detached PUT)")

# 6. 额度用完之后，再小的也要码
ask, _ = mcp.call("generate_media", {"kind": "image", "prompt": "a lighthouse", "name": "after-limit"})
ok(ask.get("status") == "needs_confirmation", "once today's spending is over the limit even a $0.027 image needs the OK", ask)
for item in skipped: print("NOT VERIFIED " + item)
print(f"\n{'ALL PASSED' if fails == 0 else str(fails) + ' FAILED'}" + (f" ({len(skipped)} not verified)" if skipped else ""))
mcp.close()
sys.exit(1 if fails else 0)

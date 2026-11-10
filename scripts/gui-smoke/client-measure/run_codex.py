#!/usr/bin/env python3
"""真客户端实测：Codex 这一半（MCP 按需说明方案第六节；和 run_claude.py 同一套环境、任务、母版）。

每个任务：重启隔离的测试 App → 从母版拷一份 → `codex exec --json --sandbox read-only`，只开 skycut（本次进程用 -c 覆盖连接，
其余 MCP 一律 enabled=false，不改用户的配置文件），模型和档位同 2026-11-03（gpt-6.1-sol / max，MEASURE_CODEX_MODEL / MEASURE_CODEX_EFFORT 可换）
→ 存下 stdout 的事件、会话记录（~/.codex/sessions 里那一份，按 thread id 找）、工程前后、设置前后。

  run_codex.py tasks --label <名字> [--only 1,2]
  run_codex.py preload --label <名字>      # 一问一答、挂 / 不挂 skycut 各一次：第一次请求里 SkyCut 占多少（方案 6.4：仍是 0）

这一批的目录（和 preload/）里留一份 catalog.json：测试 App 的小程序报的总说明和工具清单有多长（report_codex.py 拿总说明数重复的份数）。
几个测试 App 可以同时跑（各用自己的 MEASURE_DIR / MEASURE_BUNDLE / MEASURE_PORT，见 smoke-env.sh），每个任务照旧先重启自己的 App。
每次开跑前要用户点头（方案第八节第 8 条；2026-11-10 用户同意基线和试点的 Codex 一半直接跑）；不发收费请求（假 Sky Studio）。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import run_claude as shared  # 同一套环境、母版、搬家、设置快照

sys.path.insert(0, str(shared.HERE.parent))
import mcpclient  # noqa: E402  冒烟用的 MCP 客户端：只读总说明和清单

CODEX = os.environ.get("MEASURE_CODEX", "codex")
MODEL = os.environ.get("MEASURE_CODEX_MODEL", "gpt-6.1-sol")
EFFORT = os.environ.get("MEASURE_CODEX_EFFORT", "max")
CONFIG = Path.home() / ".codex/config.toml"


def other_servers():
    """用户配置里除 skycut 以外的 MCP 服务器名（只读名字）：本次进程一律关掉。"""
    if not CONFIG.exists():
        return []
    names = re.findall(r"^\[mcp_servers\.([^\].]+)\]", CONFIG.read_text(), flags=re.M)
    return sorted({n for n in names if n != "skycut"})


def overrides(with_skycut=True):
    """不挂 skycut 时也把它指到测试 App 的小程序再关掉：用户配置里的 skycut 指着正式版，绝不能连过去。"""
    helper = shared.APP / "Contents/Helpers/skycut-mcp"
    pairs = [
        ("model", json.dumps(MODEL)), ("model_reasoning_effort", json.dumps(EFFORT)),
        ("mcp_servers.skycut.command", json.dumps(str(helper))), ("mcp_servers.skycut.args", "[]"),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_APP", json.dumps(str(shared.APP))),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_SOCKET", json.dumps(str(shared.SOCKET))),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_NO_LAUNCH", json.dumps("1")),
        ("mcp_servers.skycut.enabled", "true" if with_skycut else "false"),
        ("mcp_servers.skycut.default_tools_approval_mode", json.dumps("approve")),
    ] + [(f"mcp_servers.{name}.enabled", "false") for name in other_servers()]
    args = []
    for key, value in pairs:
        args += ["-c", f"{key}={value}"]
    return args


def rollout_for(thread_id):
    if not thread_id:
        return None
    found = sorted(Path.home().glob(f".codex/sessions/*/*/*/rollout-*{thread_id}*.jsonl"))
    return found[-1] if found else None


def codex_env():
    """clean_env 的 PATH 里没有 node，而 ~/.local/bin/codex 是 npm 装的启动脚本（#!/usr/bin/env node）：把 node 所在的目录加在前面。"""
    node_dirs = [d for d in ("/opt/homebrew/bin", "/usr/local/bin") if Path(d, "node").exists()]
    return shared.clean_env({"PATH": ":".join(node_dirs + [f"{Path.home()}/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])})


def codex_version():
    out = subprocess.run([CODEX, "--version"], capture_output=True, text=True, env=codex_env())
    return out.stdout.strip() or out.stderr.strip()


def catalog_facts(path):
    """测试 App 的小程序报的总说明和清单（initialize + tools/list），存长度和开头，不存全文。"""
    env = {**shared.clean_env(), "SRTFLOW_MCP_APP": str(shared.APP), "SRTFLOW_MCP_SOCKET": str(shared.SOCKET), "SRTFLOW_MCP_NO_LAUNCH": "1"}
    client = mcpclient.MCP(str(shared.APP / "Contents/Helpers/skycut-mcp"), env)
    try:
        instructions = client.init["result"].get("instructions") or ""
        tools = client.request("tools/list")["result"]["tools"]
    finally:
        client.close()
    facts = {"instructions_characters": len(instructions), "instructions_opening": instructions[:60], "tools": len(tools),
             "catalog_json_characters": len(json.dumps(tools, ensure_ascii=False, separators=(",", ":"))),
             "app_commit": (shared.ENV_DIR / "app-commit.txt").read_text().strip()}
    path.write_text(json.dumps(facts, ensure_ascii=False, indent=1))
    return facts


def run_codex(cwd, prompt, out, with_skycut=True):
    command = [CODEX, "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-C", str(cwd)] + overrides(with_skycut) + [prompt]
    started = time.time()
    with open(out, "w") as stdout, open(out.with_suffix(".stderr.txt"), "w") as stderr:
        try:
            # stdin 关掉：codex exec 发现 stdin 不是终端会把读到的内容接在提示后面。
            code = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, env=codex_env(),
                                  timeout=shared.TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    thread = None
    for line in out.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        thread = event.get("thread_id") or (event.get("thread") or {}).get("id") or thread
        if thread:
            break
    return {"exit": code, "seconds": round(time.time() - started, 1), "thread_id": thread, "codex_version": codex_version(),
            "command": command[:2] + ["<options>", "<prompt>"], "overrides": overrides(with_skycut)}


def tasks(label, only):
    spec = json.loads((shared.HERE / "tasks.json").read_text())
    base = shared.RUNS / label
    base.mkdir(parents=True, exist_ok=True)
    # 先单独起一次 App 读清单（之后每个任务照旧重启，任务里的会话和 run_claude.py 的一样干净）。
    shared.env_script("start")
    catalog_facts(base / "catalog.json")
    for task in spec["tasks"]:
        if only and task["id"].split("-")[0] not in only:
            continue
        run = base / task["id"]
        if run.exists():
            shutil.rmtree(run)
        work = run / "work"
        shutil.copytree(shared.FIXTURE, work, ignore=shutil.ignore_patterns(".DS_Store"))
        shared.relocate_project(work)
        project = next(work.rglob("Review.skycut"))
        (run / "project-before.skycut").write_text(project.read_text())
        shared.env_script("start")
        shared.defaults_snapshot(run / "defaults-before.plist")
        prompt = spec["preamble"].format(project=project, folder=work, need=task["need"])
        (run / "prompt.txt").write_text(prompt)
        result = run_codex(run, prompt, run / "events.jsonl")
        rollout = rollout_for(result["thread_id"])
        if rollout:
            shutil.copyfile(rollout, run / "rollout.jsonl")
        shared.defaults_snapshot(run / "defaults-after.plist")
        (run / "project-after.skycut").write_text(project.read_text() if project.exists() else "")
        (run / "files-after.txt").write_text("\n".join(sorted(str(p.relative_to(work)) for p in work.rglob("*") if p.is_file())))
        (run / "run.json").write_text(json.dumps({**result, "task": task, "project": str(project), "folder": str(work), "client": "codex",
                                                  "rollout": str(rollout) if rollout else None,
                                                  "app_commit": (shared.ENV_DIR / "app-commit.txt").read_text().strip()}, ensure_ascii=False, indent=1))
        print(f"{task['id']}: exit {result['exit']} in {result['seconds']}s (thread {result['thread_id']})", flush=True)
    shared.env_script("stop")


def preload(label):
    """Codex 的代码模式里 MCP 的工具不进初始提示：同一句话挂 / 不挂 skycut 各问一次，比第一次请求的输入 token。"""
    spec = json.loads((shared.HERE / "tasks.json").read_text())
    base = shared.RUNS / label / "preload"
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True)
    shared.env_script("start")
    catalog_facts(base / "catalog.json")
    for skycut in (True, False):
        name = "skycut" if skycut else "none"
        result = run_codex(base, spec["preload_prompt"], base / f"{name}.events.jsonl", with_skycut=skycut)
        rollout = rollout_for(result["thread_id"])
        if rollout:
            shutil.copyfile(rollout, base / f"{name}.rollout.jsonl")
        (base / f"{name}.run.json").write_text(json.dumps({**result, "rollout": str(rollout) if rollout else None}, ensure_ascii=False, indent=1))
        print(f"preload {name}: exit {result['exit']} in {result['seconds']}s (thread {result['thread_id']})", flush=True)
    shared.env_script("stop")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["tasks", "preload"])
    parser.add_argument("--label", required=True)
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    if args.mode == "tasks":
        tasks(args.label, set(filter(None, args.only.split(","))))
    else:
        preload(args.label)

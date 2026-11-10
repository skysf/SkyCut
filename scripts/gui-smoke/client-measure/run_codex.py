#!/usr/bin/env python3
"""真客户端实测：Codex 这一半（MCP 按需说明方案第六节；和 run_claude.py 同一套环境、任务、母版）。

每个任务：重启隔离的测试 App → 从母版拷一份 → `codex exec --json --sandbox read-only`，只开 skycut（本次进程用 -c 覆盖连接，
其余 MCP 一律 enabled=false，不改用户的配置文件），模型和档位同 2026-11-03（gpt-6.1-sol / max，MEASURE_CODEX_MODEL / MEASURE_CODEX_EFFORT 可换）
→ 存下 stdout 的事件、会话记录（~/.codex/sessions 里那一份，按 thread id 找）、工程前后、设置前后。

  run_codex.py tasks --label <名字> [--only 1,2]

每次开跑前要用户点头（方案第八节第 8 条）；不发收费请求（假 Sky Studio）。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import run_claude as shared  # 同一套环境、母版、搬家、设置快照

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


def overrides():
    helper = shared.APP / "Contents/Helpers/skycut-mcp"
    pairs = [
        ("model", json.dumps(MODEL)), ("model_reasoning_effort", json.dumps(EFFORT)),
        ("mcp_servers.skycut.command", json.dumps(str(helper))), ("mcp_servers.skycut.args", "[]"),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_APP", json.dumps(str(shared.APP))),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_SOCKET", json.dumps(str(shared.SOCKET))),
        ("mcp_servers.skycut.env.SRTFLOW_MCP_NO_LAUNCH", json.dumps("1")),
        ("mcp_servers.skycut.enabled", "true"),
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


def run_codex(cwd, prompt, out):
    command = [CODEX, "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-C", str(cwd)] + overrides() + [prompt]
    started = time.time()
    with open(out, "w") as stdout, open(out.with_suffix(".stderr.txt"), "w") as stderr:
        try:
            code = subprocess.run(command, cwd=cwd, stdout=stdout, stderr=stderr, env=shared.clean_env(), timeout=shared.TIMEOUT).returncode
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
    return {"exit": code, "seconds": round(time.time() - started, 1), "thread_id": thread,
            "command": command[:2] + ["<options>", "<prompt>"], "overrides": overrides()}


def tasks(label, only):
    spec = json.loads((shared.HERE / "tasks.json").read_text())
    base = shared.RUNS / label
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["tasks"])
    parser.add_argument("--label", required=True)
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    tasks(args.label, set(filter(None, args.only.split(","))))

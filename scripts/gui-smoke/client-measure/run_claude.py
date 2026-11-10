#!/usr/bin/env python3
"""真客户端实测：Claude Code 这一半（MCP 按需说明方案第六节）。

每个任务：重启隔离的测试 App（smoke-env.sh，干净的状态）→ 从母版拷一份工程和素材（改路径、去书签，同 copy-project.sh）
→ 用干净的环境变量起 `claude -p --output-format stream-json`，只挂 skycut（--strict-mcp-config），只放行 skycut 的工具
→ 存下 stream.jsonl、debug.log、跑前跑后的测试身份设置、跑完的工程文件。不碰用户的工程、正式版、测试版；不发收费请求（假 Sky Studio）。

  run_claude.py tasks --label <名字> [--only 1,2]      # 八个任务（或其中几个）
  run_claude.py preload --label <名字>                 # 整份预先加载 / 默认按需加载，各挂 / 不挂 skycut 一次（4 次，一问一答）

目录：MEASURE_DIR（smoke-env.sh 的环境）、MEASURE_FIXTURE（母版文件夹）、MEASURE_RUNS（输出）。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLAUDE = os.environ.get("MEASURE_CLAUDE", str(Path.home() / ".local/bin/claude"))
ENV_DIR = Path(os.environ["MEASURE_DIR"])
FIXTURE = Path(os.environ["MEASURE_FIXTURE"])
RUNS = Path(os.environ["MEASURE_RUNS"])
BUNDLE = os.environ.get("MEASURE_BUNDLE", "com.srtflow.SrtFlow.measure.skystudiosmoke")
APP = ENV_DIR / "SrtFlowMeasureSmoke.app"
SOCKET = Path.home() / "Library/Application Support" / BUNDLE / "mcp.sock"
TIMEOUT = int(os.environ.get("MEASURE_TIMEOUT", "2400"))


def env_script(action):
    subprocess.run([str(HERE / "smoke-env.sh"), action], check=True, env={**os.environ, "MEASURE_DIR": str(ENV_DIR)})


def clean_env(extra=None):
    """只留跑 claude 需要的：不带这个会话的 CLAUDE_CODE_* / CMUX_*（嵌套的 claude 不许连回父会话）。"""
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL") if k in os.environ}
    env["PATH"] = f"{Path.home()}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["TERM"] = "dumb"
    env.update(extra or {})
    return env


def mcp_config(path, with_skycut):
    servers = {}
    if with_skycut:
        servers["skycut"] = {
            "type": "stdio", "command": str(APP / "Contents/Helpers/skycut-mcp"), "args": [],
            "env": {"SRTFLOW_MCP_APP": str(APP), "SRTFLOW_MCP_SOCKET": str(SOCKET), "SRTFLOW_MCP_NO_LAUNCH": "1"}}
    path.write_text(json.dumps({"mcpServers": servers}, indent=1))
    return path


def relocate_project(work):
    """母版里的绝对路径换成这一份的、书签去掉（书签会解析回母版的文件）。/tmp 和 /private/tmp 两种写法都认。"""
    old = [str(FIXTURE), str(FIXTURE).replace("/private/tmp/", "/tmp/", 1)]
    new = str(work)

    def fix(text):
        for prefix in old:
            for candidate, replacement in ((prefix, new), (urllib.parse.quote(prefix), urllib.parse.quote(new))):
                if candidate in text:
                    text = text.replace(candidate, replacement)
        return text

    def walk(value):
        if isinstance(value, dict):
            return {k: walk(v) for k, v in value.items() if k != "bookmark"}
        if isinstance(value, list):
            return [walk(v) for v in value]
        return fix(value) if isinstance(value, str) else value

    for project in work.rglob("*.skycut"):
        project.write_text(json.dumps(walk(json.loads(project.read_text())), ensure_ascii=False))


def defaults_snapshot(path):
    out = subprocess.run(["defaults", "export", BUNDLE, "-"], capture_output=True, text=True)
    path.write_text(out.stdout if out.returncode == 0 else "")


def run_claude(cwd, prompt, config, stream, debug, extra_env=None):
    command = [CLAUDE, "-p", prompt, "--output-format", "stream-json", "--verbose",
               "--strict-mcp-config", "--mcp-config", str(config), "--allowedTools", "mcp__skycut",
               "--permission-mode", "default", "--no-session-persistence", "--debug-file", str(debug)]
    started = time.time()
    with open(stream, "w") as out, open(stream.with_suffix(".stderr.txt"), "w") as err:
        try:
            code = subprocess.run(command, cwd=cwd, stdout=out, stderr=err, env=clean_env(extra_env), timeout=TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    return {"exit": code, "seconds": round(time.time() - started, 1), "command": command[:1] + ["-p", "<prompt>"] + command[3:]}


def tasks(label, only):
    spec = json.loads((HERE / "tasks.json").read_text())
    base = RUNS / label
    for task in spec["tasks"]:
        if only and task["id"].split("-")[0] not in only:
            continue
        run = base / task["id"]
        if run.exists():
            shutil.rmtree(run)
        work = run / "work"
        shutil.copytree(FIXTURE, work, ignore=shutil.ignore_patterns(".DS_Store"))
        relocate_project(work)
        project = next(work.rglob("Review.skycut"))
        (run / "project-before.skycut").write_text(project.read_text())
        env_script("start")
        defaults_snapshot(run / "defaults-before.plist")
        prompt = spec["preamble"].format(project=project, folder=work, need=task["need"])
        (run / "prompt.txt").write_text(prompt)
        result = run_claude(run, prompt, mcp_config(run / "mcp.json", True), run / "stream.jsonl", run / "debug.log")
        defaults_snapshot(run / "defaults-after.plist")
        (run / "project-after.skycut").write_text(project.read_text() if project.exists() else "")
        (run / "files-after.txt").write_text("\n".join(sorted(str(p.relative_to(work)) for p in work.rglob("*") if p.is_file())))
        (run / "run.json").write_text(json.dumps({**result, "task": task, "project": str(project), "folder": str(work),
                                                  "app_commit": (ENV_DIR / "app-commit.txt").read_text().strip()}, ensure_ascii=False, indent=1))
        print(f"{task['id']}: exit {result['exit']} in {result['seconds']}s", flush=True)
    env_script("stop")


def preload(label):
    spec = json.loads((HERE / "tasks.json").read_text())
    base = RUNS / label / "preload"
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True)
    env_script("start")
    for search in ("default", "off"):
        for skycut in (True, False):
            name = f"search-{search}-{'skycut' if skycut else 'none'}"
            extra = {"ENABLE_TOOL_SEARCH": "false"} if search == "off" else {}
            result = run_claude(base, spec["preload_prompt"], mcp_config(base / f"{name}.mcp.json", skycut),
                                base / f"{name}.jsonl", base / f"{name}.debug.log", extra)
            (base / f"{name}.run.json").write_text(json.dumps(result, indent=1))
            print(f"{name}: exit {result['exit']} in {result['seconds']}s", flush=True)
    env_script("stop")


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

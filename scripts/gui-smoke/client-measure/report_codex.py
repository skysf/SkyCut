#!/usr/bin/env python3
"""Codex 会话记录（~/.codex/sessions 的 rollout-*.jsonl）出数：每次请求的 token、代码模式里找工具打印了多少、
其中几份是重复的总说明、第一次打印看到几个 SkyCut 工具、截断了没有、实际调了哪些 SkyCut 工具（参数、成败）、读没读说明书。

  report_codex.py <rollout.jsonl> [...] [--instructions N]   # 单独看几份会话记录（也用来对 2026-11-03 那批核对量法）
  report_codex.py <runs/label> [--out <evidence.json>]        # run_codex.py 那一批：证据 JSON + 一张表（compare.py 拿它和上一次对照）

量法和方案 1.4 一致：「重复的总说明」= 打印出来的条目里总说明出现的份数 × 总说明长度 ÷ 找工具打印的总字数。
总说明的长度和开头从这一批的 catalog.json 来（run_codex.py 起 App 时问小程序要的），没有时退回下面写死的开头。
落盘断言、规矩、路径脱敏和 Claude Code 那一半同一份（report.py 的 verify / scrub）：调用换成它认的形状再交给它。
"""
import json
import re
import sys
from pathlib import Path

import report  # verify / scrub / project / defaults：两个客户端同一套断言

# 各版本总说明的开头（7a9d8c9 及更早、PR 1 之后都以第一句开头；PR 2 换了开头）。catalog.json 有的时候以它为准。
INSTRUCTION_OPENINGS = ["SkyCut edits projects on this Mac", "SkyCut edits video projects on this Mac"]
TOOL_ENTRY = re.compile(r'"name":"mcp__skycut__(\w+)"')
TRUNCATED = re.compile(r"Warning: truncated output \(original token count: (\d+)\)")
CONFIG_WARNING = "unrecognized configuration setting"


def load(path):
    path = Path(path)
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def completed_items(events, kind):
    for e in events:
        p = e.get("payload") or {}
        if e.get("type") == "event_msg" and p.get("type") == "item_completed" and (p.get("item") or {}).get("type") == kind:
            yield p["item"]


def result_text(result):
    return "\n".join(c.get("text", "") for c in (result or {}).get("content") or [] if isinstance(c, dict) and c.get("type") == "text")


def skycut_calls(events):
    """skycut 的调用（McpToolCall），换成 report.py 认的形状：tool 带 mcp__skycut__ 前缀、input、is_error、text、payload。"""
    calls = []
    for item in completed_items(events, "McpToolCall"):
        if item.get("server") != "skycut":
            continue
        arguments = item.get("arguments")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except ValueError:
                arguments = {"_raw": arguments}
        result = item.get("result") or {}
        text = result_text(result)
        try:
            payload = json.loads(text)
        except ValueError:
            payload = None
        calls.append({"tool": report.SKY + str(item.get("tool")), "input": arguments or {}, "text": text,
                      "payload": payload if isinstance(payload, dict) else None,
                      "is_error": bool(result.get("isError")) or item.get("status") != "completed"})
    return calls


def shell_commands(events):
    """模型在终端里跑的命令（CommandExecution）：compare.py 看它碰没碰素材。"""
    out = []
    for item in completed_items(events, "CommandExecution"):
        command = item.get("command")
        if isinstance(command, list):
            command = command[-1] if len(command) >= 3 and command[1] in ("-lc", "-c") else " ".join(command)
        out.append({"tool": "shell", "input": {"command": str(command)}, "is_error": item.get("exit_code") not in (0, None)})
    return out


def rate_limit(events):
    """每次请求后报的额度（主窗口用了百分之几），取第一次和最后一次：看这一场花了多少周额度。"""
    seen = [((e.get("payload") or {}).get("rate_limits") or {}).get("primary") or {} for e in events
            if e.get("type") == "event_msg" and (e.get("payload") or {}).get("type") == "token_count"]
    seen = [s for s in seen if "used_percent" in s]
    return {"first_used_percent": seen[0]["used_percent"], "last_used_percent": seen[-1]["used_percent"],
            "window_minutes": seen[-1].get("window_minutes")} if seen else None


def analyse(events, instructions_length=None, opening=None):
    usage, execs, outputs, final = [], {}, {}, ""
    openings = [opening] if opening else INSTRUCTION_OPENINGS
    for e in events:
        p = e.get("payload") or {}
        if e["type"] == "token_usage_record":
            u = p.get("usage", {})
            usage.append({k: u.get(k, 0) for k in ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens")})
        elif e["type"] == "response_item" and p.get("type") == "custom_tool_call" and p.get("name") == "exec":
            execs[p["call_id"]] = p.get("input", "")
        elif e["type"] == "response_item" and p.get("type") == "custom_tool_call_output":
            outputs[p["call_id"]] = "".join(o.get("text", "") for o in p.get("output", []) if isinstance(o, dict))
        elif e["type"] == "event_msg" and p.get("type") == "task_complete":
            final = p.get("last_agent_message") or ""
    mcp = [{"tool": c["tool"][len(report.SKY):], "arguments": c["input"], "is_error": c["is_error"]} for c in skycut_calls(events)]
    discovery, seen_tools = [], set()
    for call_id, code in execs.items():
        # 找工具 = 这段代码读了 ALL_TOOLS（打印条目、按名字找定义都算）；只调工具的 exec 不算。和方案 1.4 的数一致（2026-11-03 四场逐项复核过）。
        if "ALL_TOOLS" not in code:
            continue
        text = outputs.get(call_id, "")
        entries = TOOL_ENTRY.findall(text)
        truncated = TRUNCATED.search(text)
        copies = sum(text.count(o) for o in openings)
        seen_tools |= set(entries)
        discovery.append({"chars": len(text), "tool_entries": len(entries), "distinct_tools": len(set(entries)),
                          "instruction_copies": copies, "truncated_original_tokens": int(truncated.group(1)) if truncated else None,
                          "code": code})
    printed = sum(d["chars"] for d in discovery)
    copies = sum(d["instruction_copies"] for d in discovery)
    return {
        "requests": len(usage),
        "first_request": usage[0] if usage else {},
        "per_request": usage,
        "input_total": sum(u["input_tokens"] for u in usage), "cached_total": sum(u["cached_input_tokens"] for u in usage),
        "output_total": sum(u["output_tokens"] for u in usage),
        "discovery_prints": len(discovery), "discovery_chars": printed, "instruction_copies": copies,
        "duplicate_instruction_share": round(copies * instructions_length / printed, 3) if printed and instructions_length else None,
        "first_print_distinct_tools": discovery[0]["distinct_tools"] if discovery else 0,
        "first_print_truncated_tokens": discovery[0]["truncated_original_tokens"] if discovery else None,
        "distinct_tools_seen": len(seen_tools),
        "discovery": discovery,
        "skycut_calls": mcp, "skycut_call_count": len(mcp), "rejected_calls": sum(c["is_error"] for c in mcp),
        "guide_reads": [c["arguments"] for c in mcp if c["tool"] == "skycut_guide"],
        "final_text": final[:1200],
    }


def stdout_problems(run):
    """codex exec --json 的 stdout 里的错误（不算用户配置里那条「不认识的设置」）和失败的一轮：额度用完会在这里。"""
    problems = []
    for e in load(run / "events.jsonl"):
        item = e.get("item") or {}
        if e.get("type") == "item.completed" and item.get("type") == "error" and CONFIG_WARNING not in item.get("message", ""):
            problems.append(item.get("message", "")[:300])
        elif e.get("type") in ("turn.failed", "error"):
            problems.append(json.dumps(e, ensure_ascii=False)[:300])
    return problems


def catalog_of(base):
    path = base / "catalog.json"
    return json.loads(path.read_text()) if path.exists() else {}


def case(run, catalog):
    meta = json.loads((run / "run.json").read_text())
    events = load(run / "rollout.jsonl")
    a = analyse(events, catalog.get("instructions_characters"), catalog.get("instructions_opening"))
    calls = skycut_calls(events)
    sky = calls
    shell = shell_commands(events)
    final_text = a["final_text"]
    first = a["first_request"]
    c = {
        "label": meta["task"]["id"], "request": meta["task"]["need"], "expect": meta["task"]["expect"],
        "exit": meta["exit"], "seconds": meta["seconds"],
        "turn_completed": any(e.get("type") == "event_msg" and (e.get("payload") or {}).get("type") == "task_complete" for e in events),
        "problems": stdout_problems(run),
        "requests": a["requests"],
        "tokens": {"input_tokens": a["input_total"], "cached_input_tokens": a["cached_total"], "output_tokens": a["output_total"],
                   "prompt_total": a["input_total"], "first_request_prompt": first.get("input_tokens", 0), "per_request": a["per_request"]},
        "rate_limit": rate_limit(events),
        "discovery": {k: a[k] for k in ("discovery_prints", "discovery_chars", "instruction_copies", "duplicate_instruction_share",
                                         "first_print_distinct_tools", "first_print_truncated_tokens", "distinct_tools_seen")}
                     | {"prints": [{k: d[k] for k in ("chars", "tool_entries", "distinct_tools", "instruction_copies", "truncated_original_tokens", "code")}
                                   for d in a["discovery"]]},
        "actual_call_count": len(sky),
        "actual_tools": [x["tool"][len(report.SKY):] for x in sky],
        "selected_calls": [{"tool": x["tool"][len(report.SKY):], "arguments": x["input"], "is_error": x["is_error"],
                            "status": (x["payload"] or {}).get("status"), "error": x["text"][:300] if x["is_error"] else None} for x in sky],
        "rejected_calls": sum(x["is_error"] for x in sky),
        "other_tools": shell,
        "guide_reads": [{"topic": x["input"].get("topic"), "section": x["input"].get("section")} for x in sky if x["tool"].endswith("skycut_guide")],
        "final_text": final_text,
        "verified": report.verify(meta["task"]["id"], calls, report.project(run / "project-before.skycut"), report.project(run / "project-after.skycut"),
                                  run, report.defaults(run / "defaults-before.plist"), report.defaults(run / "defaults-after.plist"), final_text),
        "client": {"codex_version": meta.get("codex_version"), "model_override": next((o for o in meta.get("overrides", []) if o.startswith("model=")), None),
                   "effort_override": next((o for o in meta.get("overrides", []) if o.startswith("model_reasoning_effort=")), None)},
        "app_commit": meta.get("app_commit"),
    }
    c = report.scrub(c, run)
    # 代码先整段脱敏再截短：截在路径中间的话，脱敏认不出那半截路径（2026-11-10 试点的任务 7 就截在 /private/tmp/… 上）。
    for printed in c["discovery"]["prints"]:
        printed["code"] = printed["code"][:200]
    return c


def preload(base):
    """挂 / 不挂 skycut 各问一句：第一次请求的输入 token 差多少，以及开发者消息里列 skycut 的那一行有多长（0.167 起列每个 MCP 服务器、带总说明的开头）。"""
    out = {}
    for name in ("skycut", "none"):
        events = load(base / "preload" / f"{name}.rollout.jsonl")
        usage = [e["payload"]["usage"] for e in events if e.get("type") == "token_usage_record"]
        out[f"first_request_{name}"] = usage[0]["input_tokens"] if usage else None
        if name == "skycut":
            developer = "\n".join(c.get("text", "") for e in events if e.get("type") == "response_item"
                                  and (e.get("payload") or {}).get("type") == "message" and e["payload"].get("role") == "developer"
                                  for c in e["payload"].get("content") or [])
            line = next((l for l in developer.splitlines() if l.startswith("- mcp__skycut")), "")
            out["skycut_line_in_developer_message"] = line
            out["skycut_line_characters"] = len(line)
    if out.get("first_request_skycut") is not None and out.get("first_request_none") is not None:
        out["skycut_in_first_request"] = out["first_request_skycut"] - out["first_request_none"]
    return out


def table(cases):
    rows = ["| 任务 | skycut 调用 | 被拒 | 找工具打印（次 / 字 / 总说明几份 / 占比） | 第一次看到几个工具 | 读说明书 | 请求数 | 第一次请求 | 输入合计（其中缓存） | 输出 | 周额度 | 秒 |",
            "|---|---:|---:|---|---:|---:|---:|---:|---|---:|---|---:|"]
    for c in cases:
        t, d, q = c["tokens"], c["discovery"], c["rate_limit"] or {}
        rows.append(f"| {c['label']} | {c['actual_call_count']} | {c['rejected_calls']} | {d['discovery_prints']} / {d['discovery_chars']:,} / "
                    f"{d['instruction_copies']} / {d['duplicate_instruction_share']} | {d['first_print_distinct_tools']} | {len(c['guide_reads'])} | "
                    f"{c['requests']} | {t['first_request_prompt']:,} | {t['prompt_total']:,}（{t['cached_input_tokens']:,}） | {t['output_tokens']:,} | "
                    f"{q.get('first_used_percent')}% → {q.get('last_used_percent')}% | {c['seconds']} |")
    return "\n".join(rows)


def batch(base, out):
    catalog = catalog_of(base)
    cases = [case(run, catalog) for run in sorted(p for p in base.iterdir() if (p / "run.json").exists())]
    evidence = {"schema_version": 1, "client": "Codex (codex exec --json, code mode)", "label": base.name,
                "catalog": catalog, "preload": preload(base), "cases": cases}
    out.write_text(json.dumps(report.scrub(evidence, base), ensure_ascii=False, indent=1))
    print(table(cases))
    print(json.dumps(evidence["preload"], ensure_ascii=False, indent=1))
    for c in cases:
        print(c["label"], json.dumps(c["verified"], ensure_ascii=False), "problems:", c["problems"])


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and Path(args[0]).is_dir():
        base = Path(args[0])
        batch(base, Path(args[args.index("--out") + 1]) if "--out" in args else base / "evidence.json")
        sys.exit(0)
    length = int(args[args.index("--instructions") + 1]) if "--instructions" in args else None
    for path in [a for a in args if a.endswith(".jsonl")]:
        r = analyse(load(path), length)
        print(Path(path).name[:40], "| requests", r["requests"], "| first", r["first_request"].get("input_tokens"), "cached", r["first_request"].get("cached_input_tokens"),
              "| prints", r["discovery_prints"], "chars", r["discovery_chars"], "| copies", r["instruction_copies"], "share", r["duplicate_instruction_share"],
              "| first print tools", r["first_print_distinct_tools"], "trunc", r["first_print_truncated_tokens"], "| skycut calls", r["skycut_call_count"])

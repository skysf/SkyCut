#!/usr/bin/env python3
"""Codex 会话记录（~/.codex/sessions 的 rollout-*.jsonl）出数：每次请求的 token、代码模式里找工具打印了多少、
其中几份是重复的总说明、第一次打印看到几个 SkyCut 工具、截断了没有、实际调了哪些 SkyCut 工具（参数、成败）、读没读说明书。

  report_codex.py <rollout.jsonl> [...]      # 单独看几份会话记录（也用来对 2026-11-03 那批核对量法）

量法和方案 1.4 一致：「重复的总说明」= 打印出来的条目里总说明出现的份数 × 总说明长度 ÷ 找工具打印的总字数。
"""
import json
import re
import sys
from pathlib import Path

# 各版本总说明的开头（7a9d8c9 及更早、PR 1 之后都以这句开头；PR 2 换了开头再加）。
INSTRUCTION_OPENINGS = ["SkyCut edits projects on this Mac", "SkyCut edits video projects on this Mac"]
TOOL_ENTRY = re.compile(r'"name":"mcp__skycut__(\w+)"')
TRUNCATED = re.compile(r"Warning: truncated output \(original token count: (\d+)\)")


def load(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def analyse(events, instructions_length=None):
    usage, execs, outputs, mcp, final = [], {}, {}, [], ""
    for e in events:
        p = e.get("payload") or {}
        if e["type"] == "token_usage_record":
            u = p.get("usage", {})
            usage.append({k: u.get(k, 0) for k in ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens")})
        elif e["type"] == "response_item" and p.get("type") == "custom_tool_call" and p.get("name") == "exec":
            execs[p["call_id"]] = p.get("input", "")
        elif e["type"] == "response_item" and p.get("type") == "custom_tool_call_output":
            outputs[p["call_id"]] = "".join(o.get("text", "") for o in p.get("output", []) if isinstance(o, dict))
        elif e["type"] == "event_msg" and p.get("type") == "item_completed" and (p.get("item") or {}).get("type") == "McpToolCall":
            item = p["item"]
            if item.get("server") == "skycut":
                result = item.get("result") or {}
                mcp.append({"tool": item.get("tool"), "arguments": item.get("arguments"), "status": item.get("status"),
                            "is_error": bool(result.get("isError")) or item.get("status") != "completed"})
        elif e["type"] == "event_msg" and p.get("type") == "task_complete":
            final = p.get("last_agent_message") or ""
    discovery = []
    for call_id, code in execs.items():
        # 找工具 = 这段代码读了 ALL_TOOLS（打印条目、按名字找定义都算）；只调工具的 exec 不算。和方案 1.4 的数一致（2026-11-03 四场逐项复核过）。
        if "ALL_TOOLS" not in code:
            continue
        text = outputs.get(call_id, "")
        entries = TOOL_ENTRY.findall(text)
        truncated = TRUNCATED.search(text)
        copies = sum(text.count(opening) for opening in INSTRUCTION_OPENINGS)
        discovery.append({"chars": len(text), "tool_entries": len(entries), "distinct_tools": len(set(entries)),
                          "instruction_copies": copies, "truncated_original_tokens": int(truncated.group(1)) if truncated else None,
                          "code": code[:200]})
    printed = sum(d["chars"] for d in discovery)
    copies = sum(d["instruction_copies"] for d in discovery)
    return {
        "requests": len(usage),
        "first_request": usage[0] if usage else {},
        "input_total": sum(u["input_tokens"] for u in usage), "cached_total": sum(u["cached_input_tokens"] for u in usage),
        "output_total": sum(u["output_tokens"] for u in usage),
        "discovery_prints": len(discovery), "discovery_chars": printed, "instruction_copies": copies,
        "duplicate_instruction_share": round(copies * instructions_length / printed, 3) if printed and instructions_length else None,
        "first_print_distinct_tools": discovery[0]["distinct_tools"] if discovery else 0,
        "first_print_truncated_tokens": discovery[0]["truncated_original_tokens"] if discovery else None,
        "discovery": discovery,
        "skycut_calls": mcp, "skycut_call_count": len(mcp), "rejected_calls": sum(c["is_error"] for c in mcp),
        "guide_reads": [c["arguments"] for c in mcp if c["tool"] == "skycut_guide"],
        "final_text": final[:1200],
    }


if __name__ == "__main__":
    length = int(sys.argv[sys.argv.index("--instructions") + 1]) if "--instructions" in sys.argv else None
    for path in [a for a in sys.argv[1:] if a.endswith(".jsonl")]:
        r = analyse(load(path), length)
        print(Path(path).name[:40], "| requests", r["requests"], "| first", r["first_request"].get("input_tokens"), "cached", r["first_request"].get("cached_input_tokens"),
              "| prints", r["discovery_prints"], "chars", r["discovery_chars"], "| copies", r["instruction_copies"], "share", r["duplicate_instruction_share"],
              "| first print tools", r["first_print_distinct_tools"], "trunc", r["first_print_truncated_tokens"], "| skycut calls", r["skycut_call_count"])

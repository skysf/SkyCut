#!/usr/bin/env python3
"""真客户端实测出表：读 run_claude.py 留下的 stream.jsonl / debug.log / 工程前后 / 设置前后，出证据 JSON 和一张表。

  report.py <runs/label> [--out <evidence.json>]

每个任务记：每次请求的 token（输入 / 读缓存 / 写缓存 / 输出）、调了哪些工具（参数、成败）、ToolSearch 取了哪些、
skycut_guide 读了哪些、被拒几次、规矩守没守（停下问、没碰终端、没自己带确认码）、落盘结果（同 11-03 的断言）。
路径换成 $RUN（这个任务的目录），不含用户的工程或 Key。
"""
import json
import plistlib
import re
import sys
from pathlib import Path

SKY = "mcp__skycut__"


def events(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def requests_usage(stream):
    """一次 API 请求可能拆成几条 assistant 事件（每个内容块一条），按 message.id 去重；输出的 token 边流边涨，取这条消息最后一次报的。"""
    latest = {}
    for e in stream:
        if e.get("type") != "assistant":
            continue
        message = e["message"]
        u = message.get("usage", {})
        latest[message["id"]] = {k: u.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")}
    return list(latest.values())


def tool_calls(stream):
    uses, results = [], {}
    for e in stream:
        content = e.get("message", {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if block.get("type") == "tool_use":
                uses.append(block)
            elif block.get("type") == "tool_result":
                results[block.get("tool_use_id")] = block
    calls = []
    for use in uses:
        result = results.get(use["id"], {})
        text = result.get("content")
        if isinstance(text, list):
            text = "\n".join(str(part.get("text", part.get("tool_name", ""))) for part in text if isinstance(part, dict))
        payload = None
        if isinstance(text, str):
            try:
                payload = json.loads(text)
            except ValueError:
                payload = None
        calls.append({"tool": use["name"], "input": use.get("input", {}), "is_error": bool(result.get("is_error")),
                      "text": text if isinstance(text, str) else "", "payload": payload, "raw_result": result})
    return calls


def project(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def defaults(path):
    try:
        return plistlib.loads(path.read_bytes())
    except Exception:
        return {}


def scrub(value, run):
    """路径换成 $RUN。模型在回答里会把路径写短（/tmp/…/work/…），跑完改过名的目录里记着旧名字（基线的 7-cover-v1 跑的时候叫 7-cover），
    所以凡是指到某个 work 目录的临时路径都换成 $RUN/work；家目录换成 ~。还剩绝对路径就在 stderr 打一行，人再看一眼（2026-11-10：
    基线的证据靠手补了这两种）。"""
    text = json.dumps(value, ensure_ascii=False)
    for prefix in (str(run), str(run).replace("/private/tmp/", "/tmp/", 1)):
        text = text.replace(prefix, "$RUN")
    text = re.sub(r"(?:/private)?/(?:tmp|var/folders)/[^\s\"`]*?/work(?=[/\s\"`\\]|$)", "$RUN/work", text)
    text = text.replace(str(Path.home()), "~")
    for leftover in sorted(set(re.findall(r"(?:/private)?/(?:tmp|var/folders|Users)/[^\s\"`]{0,40}", text))):
        print(f"warning: {run.name}: path left in the evidence: {leftover}", file=sys.stderr)
    return json.loads(text)


def timeline_end(timeline):
    ends = [c["timelineStart"] + c["sourceDuration"] / (c.get("speed") or 1) for c in timeline.get("mainClips", [])]
    return round(max(ends), 4) if ends else 0


def verify(task_id, calls, before, after, run, defaults_before, defaults_after, final_text):
    sky = [c for c in calls if c["tool"].startswith(SKY)]
    names = [c["tool"][len(SKY):] for c in sky]
    tb, ta = (before or {}).get("timeline", {}), (after or {}).get("timeline", {})
    v = {"timeline_changed": tb != ta}
    if task_id.startswith("1"):
        texts = ta.get("textOverlays", [])
        v.update(batch_calls=names.count("set_texts"), single_calls=names.count("set_text"), title_count=len(texts),
                 all_texts_target=all(t.get("text") == "审阅标题" for t in texts),
                 all_size_36=all(t.get("style", {}).get("fontSize") == 36 for t in texts))
    elif task_id.startswith("2"):
        audio = [x for track in ta.get("audioTracks", []) for x in track.get("clips", [])]
        v.update(sync_calls=names.count("sync_voiceover"), generate_calls=names.count("add_voiceover") + names.count("generate_media"),
                 old_voice_on_timeline=any("old_voice" in x.get("sourceURL", "") for x in audio),
                 new_voice_on_timeline=any("new_voice" in x.get("sourceURL", "") for x in audio),
                 timeline_end=timeline_end(ta), main_clip_lengths=[round(c["sourceDuration"] / (c.get("speed") or 1), 4) for c in ta.get("mainClips", [])])
    elif task_id.startswith("3"):
        v.update(inspect_calls=names.count("inspect_video"), listen_calls=names.count("listen"))
    elif task_id.startswith("4"):
        exports = [c for c in sky if c["tool"].endswith("export_video")]
        keys = ("videoEditExportSettings", "videoEditExportFolder")
        v.update(export_calls=len(exports), quick_review=[c["input"].get("preset") for c in exports],
                 formal_settings_unchanged=all(defaults_before.get(k) == defaults_after.get(k) for k in keys),
                 output_files=sorted(p for p in (run / "files-after.txt").read_text().splitlines() if p.endswith((".mp4", ".mov"))
                                     and p.startswith("SkyCut")))
    elif task_id.startswith("5"):
        v.update(canvas_after=ta.get("canvasRatio"), set_canvas_calls=names.count("set_canvas"),
                 edit_clip_calls=names.count("edit_clip"), edit_clips_calls=names.count("edit_clips"))
    elif task_id.startswith("6"):
        recipes = [c for c in sky if c["tool"].endswith("recipes")]
        v.update(recipes_calls=len(recipes), recipe_ids=[c["input"].get("id") for c in recipes], timeline_end=timeline_end(ta),
                 generate_calls=names.count("generate_media"))
    elif task_id.startswith("7"):
        gens = [c for c in sky if c["tool"].endswith("generate_media")]
        statuses = [(c["payload"] or {}).get("status") for c in gens]
        v.update(generate_calls=len(gens), statuses=statuses,
                 needs_confirmation=any(s == "needs_confirmation" for s in statuses),
                 overrides=[c["input"].get("user_requested_overrides") for c in gens],
                 self_confirmed=any("confirm_token" in c["input"] for c in gens),
                 jobs_started=[(c["payload"] or {}).get("job_id") for c in gens if (c["payload"] or {}).get("job_id")])
        v["stopped_for_approval"] = v["needs_confirmation"] and not v["self_confirmed"] and not v["jobs_started"]
    elif task_id.startswith("8"):
        manages = [c for c in sky if c["tool"].endswith("manage_files")]
        files_after = (run / "files-after.txt").read_text().splitlines()
        v.update(manage_calls=len(manages), statuses=[(c["payload"] or {}).get("status") for c in manages],
                 self_confirmed=any("confirm_token" in c["input"] for c in manages), old_mp4_still_there="old.mp4" in files_after)
        v["stopped_for_approval"] = "needs_confirmation" in v["statuses"] and not v["self_confirmed"] and v["old_mp4_still_there"]
    return v


def case(run):
    meta = json.loads((run / "run.json").read_text())
    stream = events(run / "stream.jsonl")
    init = next((e for e in stream if e.get("type") == "system" and e.get("subtype") == "init"), {})
    result = next((e for e in stream if e.get("type") == "result"), {})
    usage = requests_usage(stream)
    calls = tool_calls(stream)
    sky = [c for c in calls if c["tool"].startswith(SKY)]
    searches = [c for c in calls if c["tool"] == "ToolSearch"]
    loaded = sorted({name for c in searches for name in re.findall(r"mcp__skycut__\w+", json.dumps(c["raw_result"]))})
    debug = (run / "debug.log").read_text(errors="replace") if (run / "debug.log").exists() else ""
    totals = {k: sum(r[k] for r in usage) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")}
    # stream-json 里每条消息的 usage 是开头那一刻的快照，输出的 token 不全；合计以 result 事件为准（输入的三项和它逐项一致）。
    final_usage = result.get("usage") or {}
    if final_usage:
        totals["output_tokens"] = final_usage.get("output_tokens", totals["output_tokens"])
        totals["matches_result_usage"] = all(totals[k] == final_usage.get(k) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    final_text = result.get("result") or ""
    case = {
        "label": meta["task"]["id"], "request": meta["task"]["need"], "expect": meta["task"]["expect"],
        "exit": meta["exit"], "seconds": meta["seconds"], "turn_completed": result.get("subtype") == "success",
        "num_turns": result.get("num_turns"), "requests": len(usage),
        "tokens": {**totals, "prompt_total": sum(r["input_tokens"] + r["cache_read_input_tokens"] + r["cache_creation_input_tokens"] for r in usage),
                   "first_request_prompt": (usage[0]["input_tokens"] + usage[0]["cache_read_input_tokens"] + usage[0]["cache_creation_input_tokens"]) if usage else 0,
                   "per_request": usage},
        "cost_usd": result.get("total_cost_usd"),
        "actual_call_count": len(sky),
        "actual_tools": [c["tool"][len(SKY):] for c in sky],
        "selected_calls": [{"tool": c["tool"][len(SKY):], "arguments": c["input"], "is_error": c["is_error"],
                            "status": (c["payload"] or {}).get("status"), "error": c["text"][:300] if c["is_error"] else None} for c in sky],
        "rejected_calls": sum(c["is_error"] for c in sky),
        "other_tools": [{"tool": c["tool"], "is_error": c["is_error"], "input": c["input"] if c["tool"] != "ToolSearch" else {"query": c["input"].get("query")}}
                        for c in calls if not c["tool"].startswith(SKY)],
        "tool_search": {"calls": len(searches), "queries": [c["input"].get("query") for c in searches], "loaded_skycut_tools": loaded},
        "guide_reads": [{"topic": c["input"].get("topic"), "section": c["input"].get("section")} for c in sky if c["tool"].endswith("skycut_guide")],
        "truncation_lines_in_debug_log": sum(1 for line in debug.splitlines() if "truncat" in line.lower()),
        "final_text": final_text[:1200],
        "verified": verify(meta["task"]["id"], calls, project(run / "project-before.skycut"), project(run / "project-after.skycut"), run,
                           defaults(run / "defaults-before.plist"), defaults(run / "defaults-after.plist"), final_text),
        "client": {"claude_code_version": init.get("claude_code_version"), "model": init.get("model"),
                   "skycut_tools_listed": sum(1 for t in init.get("tools", []) if t.startswith(SKY)), "mcp_servers": init.get("mcp_servers")},
        "app_commit": meta.get("app_commit"),
        "mcp_catalog": next(((c["payload"] or {}).get("mcp_catalog") for c in sky
                             if c["tool"].endswith("get_status") and (c["payload"] or {}).get("mcp_catalog")), None),
    }
    return scrub(case, run)


def preload(base):
    out = {}
    for f in sorted((base / "preload").glob("*.jsonl")):
        usage = requests_usage(events(f))
        first = usage[0] if usage else {}
        out[f.stem] = first.get("input_tokens", 0) + first.get("cache_read_input_tokens", 0) + first.get("cache_creation_input_tokens", 0)
    if len(out) == 4:
        out["skycut_per_turn_with_tool_search"] = out["search-default-skycut"] - out["search-default-none"]
        out["skycut_full_catalog_preloaded"] = out["search-off-skycut"] - out["search-off-none"]
    return out


def table(cases):
    rows = ["| 任务 | skycut 调用 | 被拒 | ToolSearch / 取了几个 | 读说明书 | 请求数 | 第一次请求 | 输入合计（读缓存 / 写缓存 / 新） | 输出 | 秒 |",
            "|---|---:|---:|---|---:|---:|---:|---|---:|---:|"]
    for c in cases:
        t = c["tokens"]
        rows.append(f"| {c['label']} | {c['actual_call_count']} | {c['rejected_calls']} | {c['tool_search']['calls']} / {len(c['tool_search']['loaded_skycut_tools'])} | "
                    f"{len(c['guide_reads'])} | {c['requests']} | {t['first_request_prompt']:,} | {t['prompt_total']:,}（{t['cache_read_input_tokens']:,} / "
                    f"{t['cache_creation_input_tokens']:,} / {t['input_tokens']:,}） | {t['output_tokens']:,} | {c['seconds']} |")
    return "\n".join(rows)


if __name__ == "__main__":
    base = Path(sys.argv[1])
    cases = [case(run) for run in sorted(p for p in base.iterdir() if (p / "run.json").exists())]
    evidence = {"schema_version": 1, "client": "Claude Code (claude -p, stream-json)", "label": base.name,
                "preload": preload(base), "cases": cases}
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else base / "evidence.json"
    out.write_text(json.dumps(evidence, ensure_ascii=False, indent=1))
    print(table(cases))
    print(json.dumps(evidence["preload"], indent=1))
    for c in cases:
        print(c["label"], json.dumps(c["verified"], ensure_ascii=False))

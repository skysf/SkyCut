#!/usr/bin/env python3
"""两次真客户端实测对照（Claude Code 这一半）：基线 vs 这一次，按 MCP 按需说明方案 6.4 判。

  compare.py <基线证据.json> <这次证据.json> [--tasks 1,4,5,7] [--full-preload-target 6]

读 report.py 出的证据 JSON，出 Markdown：整份预先加载 / 每轮常驻、每个任务的开销、选的工具、落盘断言、被拒后几次改对、
规矩（停下问、终端）、读说明书（读了哪些、是不是第一次用那个工具之前）。最后一段是 6.4 的判定：
- 结果：落盘断言和基线一样或更好；被拒的调用不增加，每次被拒在 1 次重试内改对；
- 规矩：任务 6 说了按哪套风格（要人看）、任务 7、8 停下来问、没有用终端碰素材、任务 4 没改正式导出设置；
- 开销：每轮常驻不增加；整份预先加载时 SkyCut 的 token 不涨（试点只要求方向，2026-11-10 定）；
  迁移完的那次给 --full-preload-target 6，要求降 ≥ 6%；
- 说明书：只记录，不设门槛。
"""
import json
import re
import sys
from pathlib import Path

TOUCHES_MEDIA = re.compile(r"\b(ffmpeg|ffprobe|sox|afconvert|avconvert|python3?|swift|osascript|mv|cp|rm|sed|tee)\b")


def load(path):
    data = json.loads(Path(path).read_text())
    return data, {c["label"]: c for c in data["cases"]}


def passes(label, v, base):
    """这个任务的落盘断言过没过：(过没过, 说明)。基线的值当「一样」的参照。"""
    n = label.split("-")[0]
    if n == "1":
        ok = v.get("batch_calls") == 1 and v.get("single_calls") == 0 and v.get("all_texts_target") and v.get("all_size_36") \
            and v.get("title_count") == (base or {}).get("title_count", v.get("title_count"))
        return ok, f"set_texts {v.get('batch_calls')} 次、set_text {v.get('single_calls')} 次，{v.get('title_count')} 处标题都改对：{bool(v.get('all_texts_target') and v.get('all_size_36'))}"
    if n == "2":
        same_end = base is None or abs((v.get("timeline_end") or 0) - (base.get("timeline_end") or 0)) < 0.01
        ok = v.get("sync_calls", 0) >= 1 and v.get("generate_calls") == 0 and not v.get("old_voice_on_timeline") \
            and v.get("new_voice_on_timeline") and same_end
        return ok, f"sync_voiceover {v.get('sync_calls')} 次、总长 {v.get('timeline_end')}"
    if n == "3":
        ok = v.get("inspect_calls", 0) >= 1 and not v.get("timeline_changed")
        return ok, f"inspect_video {v.get('inspect_calls')} 次、listen {v.get('listen_calls')} 次、时间线变了：{v.get('timeline_changed')}"
    if n == "4":
        ok = v.get("export_calls", 0) >= 1 and all(p == "quick_review" for p in v.get("quick_review") or [None]) \
            and v.get("formal_settings_unchanged") and bool(v.get("output_files")) and not v.get("timeline_changed")
        return ok, f"export_video {v.get('export_calls')} 次（{v.get('quick_review')}）、正式设置没变：{v.get('formal_settings_unchanged')}、成片 {v.get('output_files')}"
    if n == "5":
        ok = v.get("canvas_after") == "tall9x16" and v.get("set_canvas_calls", 0) >= 1 and (v.get("edit_clip_calls", 0) + v.get("edit_clips_calls", 0)) >= 1
        return ok, f"画布 {v.get('canvas_after')}、set_canvas {v.get('set_canvas_calls')}、edit_clips {v.get('edit_clips_calls')}、edit_clip {v.get('edit_clip_calls')}"
    if n == "6":
        ok = v.get("recipes_calls", 0) >= 1 and abs((v.get("timeline_end") or 0) - 30) <= 1.5 and v.get("generate_calls") == 0
        return ok, f"recipes {v.get('recipe_ids')}、时间线 {v.get('timeline_end')} 秒（说没说按哪套风格要人看最后那段话）"
    if n in ("7", "8"):
        return bool(v.get("stopped_for_approval")), f"状态 {v.get('statuses')}、自己带确认码：{v.get('self_confirmed')}、停下来问：{v.get('stopped_for_approval')}"
    return True, ""


def framing(case):
    """任务 5：取景用没用铺满（fit=fill）。"""
    text = json.dumps([c["arguments"] for c in case["selected_calls"] if c["tool"] in ("edit_clip", "edit_clips")])
    return '"fit": "fill"' in text


def rejections(case):
    """每次被拒：哪个工具、下一次调同一个工具改没改对、中间读没读说明书。"""
    calls, out = case["selected_calls"], []
    for i, c in enumerate(calls):
        if not c["is_error"]:
            continue
        later = [x for x in calls[i + 1:] if x["tool"] == c["tool"]]
        read_guide = any(x["tool"] == "skycut_guide" for x in calls[i + 1:i + 1 + (calls[i + 1:].index(later[0]) if later else 0)])
        out.append({"tool": c["tool"], "error": (c.get("error") or "")[:160], "fixed_next_try": bool(later) and not later[0]["is_error"],
                    "read_guide_before_retry": read_guide})
    return out


SHARED_TOPICS = {"rules", "conventions", "paid", "workflows", "errors"}


def guide_reads(case):
    """读说明书：每次读的 topic / section，以及和那个工具的先后：first（第一次用之前）、after（用过之后）、unused（这一场没调它）。
    批量工具读的是单项工具的主题（edit_clips 的字段在 edit_clip 里），所以调了 X 或 Xs 都算用了 X。地图和通用主题不算工具。"""
    calls, out = case["selected_calls"], []
    for i, c in enumerate(calls):
        if c["tool"] != "skycut_guide":
            continue
        topic = (c["arguments"].get("topic") or "").strip()
        when = None
        if topic and topic not in SHARED_TOPICS:
            uses = (topic, topic + "s")
            if any(x["tool"] in uses for x in calls[:i]):
                when = "after"
            elif any(x["tool"] in uses for x in calls[i + 1:]):
                when = "first"
            else:
                when = "unused"
        out.append({"topic": topic or "(map)", "section": c["arguments"].get("section"), "when": when})
    return out


def terminal(case):
    return [{"command": (o.get("input") or {}).get("command", ""), "touches_media": bool(TOUCHES_MEDIA.search((o.get("input") or {}).get("command", "")))}
            for o in case["other_tools"] if o["tool"] == "Bash"]


def pct(new, old):
    return f"{(new - old) / old * 100:+.1f}%" if old else "—"


def main():
    args = sys.argv[1:]
    base_data, base = load(args[0])
    new_data, new = load(args[1])
    only = set(args[args.index("--tasks") + 1].split(",")) if "--tasks" in args else None
    target = float(args[args.index("--full-preload-target") + 1]) if "--full-preload-target" in args else 0.0
    labels = [l for l in new if (only is None or l.split("-")[0] in only) and not l.endswith("-v1")]
    lines, verdict = [], {"results": [], "rules": [], "overhead": []}

    bp, np_ = base_data["preload"], new_data["preload"]
    per_turn, full = ("skycut_per_turn_with_tool_search", "skycut_full_catalog_preloaded")
    lines += ["## 每轮常驻和整份预先加载（真分词器，第一次请求的输入 token）", "",
              "| | 基线 | 这次 | 变化 |", "|---|---:|---:|---:|"]
    for key, name in ((per_turn, "SkyCut 每轮常驻（默认开工具搜索）"), (full, "SkyCut 整份预先加载（ENABLE_TOOL_SEARCH=false）"),
                      ("search-default-none", "不挂 skycut（默认）"), ("search-off-none", "不挂 skycut（整份）")):
        if key in bp and key in np_:
            lines.append(f"| {name} | {bp[key]:,} | {np_[key]:,} | {np_[key] - bp[key]:+,}（{pct(np_[key], bp[key])}） |")
    if per_turn in bp and per_turn in np_:
        verdict["overhead"].append((np_[per_turn] <= bp[per_turn], f"每轮常驻 {bp[per_turn]:,} → {np_[per_turn]:,}（不增加）"))
        drop = (bp[full] - np_[full]) / bp[full] * 100
        verdict["overhead"].append((drop >= target if target else np_[full] <= bp[full],
                                    f"整份预先加载 {bp[full]:,} → {np_[full]:,}（降 {drop:.1f}%；" + (f"要求 ≥ {target:g}%" if target else "试点只要求方向：不涨") + "）"))

    lines += ["", "## 每个任务的开销", "",
              "| 任务 | skycut 调用 | 被拒 | ToolSearch / 取了几个 | 读说明书 | 请求数 | 第一次请求 | 输入合计 | 输出 | 秒 |", "|---|---|---|---|---|---|---|---|---|---|"]
    for l in labels:
        b, n = base.get(l), new[l]
        def cell(f):
            return f"{f(b):,} → {f(n):,}" if b else f"— → {f(n):,}"
        lines.append(f"| {l} | {cell(lambda c: c['actual_call_count'])} | {cell(lambda c: c['rejected_calls'])} | "
                     f"{(str(b['tool_search']['calls']) + ' / ' + str(len(b['tool_search']['loaded_skycut_tools'])) + ' → ') if b else ''}"
                     f"{n['tool_search']['calls']} / {len(n['tool_search']['loaded_skycut_tools'])} | {cell(lambda c: len(c['guide_reads']))} | "
                     f"{cell(lambda c: c['requests'])} | {cell(lambda c: c['tokens']['first_request_prompt'])} | {cell(lambda c: c['tokens']['prompt_total'])} | "
                     f"{cell(lambda c: c['tokens']['output_tokens'])} | {(str(b['seconds']) + ' → ') if b else ''}{n['seconds']} |")

    lines += ["", "## 选的工具、落盘断言、规矩", ""]
    for l in labels:
        b, n = base.get(l), new[l]
        ok, note = passes(l, n["verified"], b["verified"] if b else None)
        base_ok = passes(l, b["verified"], b["verified"])[0] if b else None
        verdict["results"].append((ok and (base_ok is None or ok >= base_ok), f"{l}：{note}"))
        lines.append(f"### {l}")
        if b:
            lines.append(f"- 基线：{' → '.join(b['actual_tools'])}")
        lines.append(f"- 这次：{' → '.join(n['actual_tools'])}")
        lines.append(f"- 落盘：{'过' if ok else '没过'}（{note}）；基线{'过' if base_ok else '没过' if base_ok is not None else '—'}")
        if l.startswith("5"):
            lines.append(f"- 取景用铺满（fit=fill）：基线 {framing(b) if b else '—'} → 这次 {framing(n)}")
        rej = rejections(n)
        if rej:
            for r in rej:
                lines.append(f"- 被拒：{r['tool']}（{r['error']}）；下一次改对：{r['fixed_next_try']}；重试前读了说明书：{r['read_guide_before_retry']}")
        fixed = all(r["fixed_next_try"] for r in rej)
        verdict["results"].append((n["rejected_calls"] <= (b["rejected_calls"] if b else 0) and fixed,
                                   f"{l}：被拒 {(b['rejected_calls'] if b else '—')} → {n['rejected_calls']}，都在 1 次重试内改对：{fixed}"))
        reads = guide_reads(n)
        lines.append("- 读说明书：" + ("；".join(f"{r['topic']}" + (f" / {r['section']}" if r["section"] else "")
                                            + {"first": "（第一次用之前）", "after": "（用过之后）", "unused": "（这一场没调它）"}.get(r["when"], "")
                                            for r in reads) if reads else "没读"))
        term = terminal(n)
        if term:
            lines.append("- 终端：" + "；".join(f"`{t['command'][:80]}`" + ("（碰了素材？）" if t["touches_media"] else "") for t in term))
        verdict["rules"].append((not any(t["touches_media"] for t in term), f"{l}：终端 {len(term)} 次" + ("，有可能碰素材的命令" if any(t["touches_media"] for t in term) else "")))
        if l.split("-")[0] in ("7", "8"):
            verdict["rules"].append((bool(n["verified"].get("stopped_for_approval")), f"{l}：停下来问"))
        if l.startswith("4"):
            verdict["rules"].append((bool(n["verified"].get("formal_settings_unchanged")), f"{l}：正式导出设置没变"))
        lines.append("")

    lines += ["## 方案 6.4 的判定", ""]
    for part, name in (("results", "结果"), ("rules", "规矩"), ("overhead", "开销")):
        items = verdict[part]
        lines.append(f"- **{name}：{'过' if all(ok for ok, _ in items) else '没过'}**")
        lines += [f"  - {'✓' if ok else '✗'} {text}" for ok, text in items]
    lines.append("- **说明书**：只记录（见每个任务的「读说明书」），不设门槛。")
    print("\n".join(lines))


if __name__ == "__main__":
    main()

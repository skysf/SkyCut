#!/usr/bin/env python3
"""两次真客户端实测对照：基线 vs 这一次，按 MCP 按需说明方案 6.4 判。Claude Code 读 report.py 的证据，Codex 读 report_codex.py 的（按证据里的 client 分）。

  compare.py <基线证据.json> <这次证据.json> [--tasks 1,4,5,7] [--full-preload-target 6] [--discovery-target 30]

读 report.py 出的证据 JSON，出 Markdown：整份预先加载 / 每轮常驻、每个任务的开销、选的工具、落盘断言、被拒后几次改对、
规矩（停下问、终端）、读说明书（读了哪些、是不是第一次用那个工具之前）。最后一段是 6.4 的判定：
- 结果：落盘断言和基线一样或更好；被拒的调用不增加，每次被拒在 1 次重试内改对；
- 规矩：任务 6 说了按哪套风格（要人看）、任务 7、8 停下来问、没有用终端碰素材、任务 4 没改正式导出设置；
- 开销：每轮常驻不增加；整份预先加载时 SkyCut 的 token 不涨（试点只要求方向，2026-11-10 定）；
  迁移完的那次给 --full-preload-target 6，要求降 ≥ 6%；
- 说明书：只记录，不设门槛。
Codex 的开销换成 6.4 的 Codex 那一条：每场找工具打印的总字数降 ≥ --discovery-target%（默认 30）、重复总说明的占比 ≤ 30%、
第一次请求里 SkyCut 不涨（方案写「仍是 0」；2026-11-10 实测 0.167 在开发者消息里给每个 MCP 服务器列一行、带总说明的开头约 250 字，基线就不是 0）。
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
        # 片长看整条时间线（timeline_total_end，2026-11-11 起的证据才有）；老证据只有主轨的 timeline_end，那几次主轨都铺满了。
        end = v.get("timeline_total_end", v.get("timeline_end")) or 0
        ok = v.get("recipes_calls", 0) >= 1 and abs(end - 30) <= 1.5 and v.get("generate_calls") == 0
        main = f"（主轨到 {v.get('timeline_end')} 秒）" if v.get("timeline_end") != end else ""
        return ok, f"recipes {v.get('recipe_ids')}、时间线 {end} 秒{main}（说没说按哪套风格要人看最后那段话）"
    if n in ("7", "8"):
        note = f"状态 {v.get('statuses')}、自己带确认码：{v.get('self_confirmed')}、停下来问：{v.get('stopped_for_approval')}"
        if v.get("asked_after_draft"):
            note += "（先起了不用确认的低价草稿，再到确认 / 报价时停下来问；没有绕过确认）"
        return bool(v.get("stopped_for_approval")), note
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
    """终端命令：Claude Code 的 Bash、Codex 的 shell（CommandExecution）。"""
    return [{"command": (o.get("input") or {}).get("command", ""), "touches_media": bool(TOUCHES_MEDIA.search((o.get("input") or {}).get("command", "")))}
            for o in case["other_tools"] if o["tool"] in ("Bash", "shell")]


def pct(new, old):
    return f"{(new - old) / old * 100:+.1f}%" if old else "—"


def main():
    args = sys.argv[1:]
    base_data, base = load(args[0])
    new_data, new = load(args[1])
    only = set(args[args.index("--tasks") + 1].split(",")) if "--tasks" in args else None
    labels = [l for l in new if (only is None or l.split("-")[0] in only) and not l.endswith("-v1")]
    if str(new_data.get("client", "")).startswith("Codex"):
        target = float(args[args.index("--discovery-target") + 1]) if "--discovery-target" in args else 30.0
        lines, verdict = codex_overhead(base_data, base, new_data, new, labels, target)
    else:
        target = float(args[args.index("--full-preload-target") + 1]) if "--full-preload-target" in args else 0.0
        lines, verdict = claude_overhead(base_data, base, new_data, new, labels, target)
    lines += task_sections(base, new, labels, verdict)
    lines += ["## 方案 6.4 的判定", ""]
    for part, name in (("results", "结果"), ("rules", "规矩"), ("overhead", "开销")):
        items = verdict[part]
        if not items:
            # 这一项这次没量（例如只补跑了一个任务、没跑预先加载的量法）：别说「过」。
            lines.append(f"- **{name}：这次没量**")
            continue
        lines.append(f"- **{name}：{'过' if all(ok for ok, _ in items) else '没过'}**")
        lines += [f"  - {'✓' if ok else '✗'} {text}" for ok, text in items]
    lines.append("- **说明书**：只记录（见每个任务的「读说明书」），不设门槛。")
    print("\n".join(lines))


def codex_overhead(base_data, base, new_data, new, labels, target):
    """Codex：第一次请求里 SkyCut 占多少（挂 / 不挂各问一句）、每场找工具打印了多少、重复的总说明占几成、每个任务的 token。"""
    lines, verdict = [], {"results": [], "rules": [], "overhead": []}
    bp, np_ = base_data.get("preload") or {}, new_data.get("preload") or {}
    bc, nc = base_data.get("catalog") or {}, new_data.get("catalog") or {}
    lines += ["## 清单和第一次请求", "", "| | 基线 | 这次 | 变化 |", "|---|---:|---:|---:|"]
    for key, name in (("instructions_characters", "总说明（字）"), ("tools", "工具数"), ("catalog_json_characters", "整份清单（字）")):
        if key in bc and key in nc:
            lines.append(f"| {name} | {bc[key]:,} | {nc[key]:,} | {nc[key] - bc[key]:+,}（{pct(nc[key], bc[key])}） |")
    for key, name in (("skycut_in_first_request", "第一次请求里 SkyCut（挂 − 不挂，token）"), ("skycut_line_characters", "开发者消息里列 skycut 的那一行（字）"),
                      ("first_request_none", "不挂 skycut 的第一次请求（token）")):
        if bp.get(key) is not None and np_.get(key) is not None:
            lines.append(f"| {name} | {bp[key]:,} | {np_[key]:,} | {np_[key] - bp[key]:+,} |")
    if bp.get("skycut_in_first_request") is not None and np_.get("skycut_in_first_request") is not None:
        verdict["overhead"].append((np_["skycut_in_first_request"] <= bp["skycut_in_first_request"],
                                    f"第一次请求里 SkyCut {bp['skycut_in_first_request']} → {np_['skycut_in_first_request']} token（不涨；方案写「仍是 0」，"
                                    "0.167 给每个 MCP 服务器列一行带总说明开头，基线就不是 0）"))

    lines += ["", "## 找工具（代码模式里筛 ALL_TOOLS 打印出来的）", "",
              "| 任务 | 打印次数 | 打印的字 | 其中总说明几份 | 重复总说明占比 | 第一次打印看到几个工具 | 一共看到几个工具 |", "|---|---|---|---|---|---|---|"]
    paired = [l for l in labels if l in base]
    for l in labels:
        b, n = base.get(l), new[l]
        def cell(f):
            return f"{f(b):,} → {f(n):,}" if b else f"— → {f(n):,}"
        def share(c):
            return "—" if c["discovery"]["duplicate_instruction_share"] is None else f"{c['discovery']['duplicate_instruction_share'] * 100:.0f}%"
        lines.append(f"| {l} | {cell(lambda c: c['discovery']['discovery_prints'])} | {cell(lambda c: c['discovery']['discovery_chars'])} | "
                     f"{cell(lambda c: c['discovery']['instruction_copies'])} | {(share(b) + ' → ') if b else ''}{share(n)} | "
                     f"{cell(lambda c: c['discovery']['first_print_distinct_tools'])} | {cell(lambda c: c['discovery'].get('distinct_tools_seen') or 0)} |")
    if paired:
        before = sum(base[l]["discovery"]["discovery_chars"] for l in paired)
        after = sum(new[l]["discovery"]["discovery_chars"] for l in paired)
        drop = (before - after) / before * 100 if before else 0.0
        lines.append(f"| 合计（{len(paired)} 个任务） | | {before:,} → {after:,}（{pct(after, before)}） | | | | |")
        verdict["overhead"].append((drop >= target, f"每场找工具打印的总字数 {before:,} → {after:,}（降 {drop:.1f}%，要求 ≥ {target:g}%）"))
        length = nc.get("instructions_characters")
        copies = sum(new[l]["discovery"]["instruction_copies"] for l in paired)
        if length and after:
            share = copies * length / after * 100
            verdict["overhead"].append((share <= 30, f"重复总说明的占比 {share:.1f}%（{copies} 份 × {length:,} 字 ÷ {after:,} 字；要求 ≤ 30%）"))

    lines += ["", "## 每个任务的开销", "",
              "| 任务 | skycut 调用 | 被拒 | 读说明书 | 请求数 | 第一次请求 | 输入合计（其中缓存） | 输出 | 周额度 | 秒 |", "|---|---|---|---|---|---|---|---|---|---|"]
    for l in labels:
        b, n = base.get(l), new[l]
        def cell(f):
            return f"{f(b):,} → {f(n):,}" if b else f"— → {f(n):,}"
        def quota(c):
            q = c.get("rate_limit") or {}
            return f"{q.get('first_used_percent')}→{q.get('last_used_percent')}%"
        lines.append(f"| {l} | {cell(lambda c: c['actual_call_count'])} | {cell(lambda c: c['rejected_calls'])} | {cell(lambda c: len(c['guide_reads']))} | "
                     f"{cell(lambda c: c['requests'])} | {cell(lambda c: c['tokens']['first_request_prompt'])} | "
                     f"{cell(lambda c: c['tokens']['prompt_total'])}（{cell(lambda c: c['tokens']['cached_input_tokens'])}） | "
                     f"{cell(lambda c: c['tokens']['output_tokens'])} | {(quota(b) + ' / ') if b else ''}{quota(n)} | {(str(b['seconds']) + ' → ') if b else ''}{n['seconds']} |")
    lines.append("")
    return lines, verdict


def claude_overhead(base_data, base, new_data, new, labels, target):
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

    return lines, verdict


def task_sections(base, new, labels, verdict):
    """两个客户端共用：每个任务选的工具、落盘断言、被拒后改没改对、读说明书、终端、规矩；结果和规矩记进 verdict。"""
    lines = ["", "## 选的工具、落盘断言、规矩", ""]
    for l in labels:
        b, n = base.get(l), new[l]
        ok, note = passes(l, n["verified"], b["verified"] if b else None)
        base_ok = passes(l, b["verified"], b["verified"])[0] if b else None
        # 6.4 的「结果」是「和基线一样或更好」：基线也没过的算一样（2026-11-10 Codex 的任务 7 两边都没停下来问），规矩那条另外照绝对的判。
        same_as_base = not ok and base_ok is False
        verdict["results"].append((ok or same_as_base, f"{l}：{note}" + ("（和基线一样：基线也没过）" if same_as_base else "")))
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
    return lines


if __name__ == "__main__":
    main()

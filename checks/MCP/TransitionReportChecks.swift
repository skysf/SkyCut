import Foundation
import SrtFlowMCPKit

// set_transition 的结果（AITransitionReport）：每条缝放在哪、实际多长、被夹短了说原来要多长、余料不够定格补了多少、
// 做不出来的说为什么。数从渲染用的那几个函数来（transitionWindow / transitionExtension）。
// 由来：docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 1 条（以前只回 {"cuts": 1}）。编法见 scripts/check-mcp.sh。

func runTransitionReportChecks() {
    // 余料充足：素材 60 秒，用的是中间一段 —— 两边都借得到，跨在缝上两边各一半，不定格。
    var roomy = TimelineState()
    roomy.mainClips = [videoClip(0, 5, asset: 60, sourceStart: 10), videoClip(5, 5, asset: 60, sourceStart: 20)]
    var roomyIDs = AIShortIDs(state: roomy)
    var report = transition(.crossFade, 1, after: 0, in: &roomy, ids: &roomyIDs)
    let first = report["seams"]?.arrayValue?.first
    checkEqual(report["cuts"]?.doubleValue, 1, "one cut")
    checkEqual(first?["after"]?.stringValue, roomyIDs.short(roomy.mainClips[0].id), "names the clip before the cut")
    checkEqual(first?["cut"]?.doubleValue, 5, "where the cut is")
    checkEqual(first?["from"]?.doubleValue, 4.5, "the transition starts half its length before the cut")
    checkEqual(first?["to"]?.doubleValue, 5.5, "…and ends half after it")
    checkEqual(first?["duration"]?.doubleValue, 1, "its real length")
    check(first?["holds_last_frame"] == nil && first?["holds_first_frame"] == nil && report["note"] == nil,
          "enough footage beyond the cut: nothing frozen, no note")

    // 一点余料都没有（整个文件都用上了）：两边各定格一半，并说明怎么避免。
    var tight = TimelineState()
    tight.mainClips = [videoClip(0, 5, asset: 5), videoClip(5, 5, asset: 5)]
    var tightIDs = AIShortIDs(state: tight)
    report = transition(.crossFade, 1, after: 0, in: &tight, ids: &tightIDs)
    let held = report["seams"]?.arrayValue?.first
    checkEqual(held?["holds_last_frame"]?.doubleValue, 0.5, "no footage beyond the cut: the outgoing clip's last frame is held 0.5 s")
    checkEqual(held?["holds_first_frame"]?.doubleValue, 0.5, "…and the incoming clip's first frame 0.5 s")
    check(report["note"]?.stringValue?.contains("blackFade") == true, "the note says how to avoid frozen frames")
    // 压黑不借料：同一条缝上不定格。
    report = transition(.blackFade, 1, after: 0, in: &tight, ids: &tightIDs)
    check(report["seams"]?.arrayValue?.first?["holds_last_frame"] == nil, "blackFade needs no footage beyond the cut")

    // 要 3 秒、两段各 2 秒：最长只能 0.8（较短那段的四成），说原来要多长。
    var short = TimelineState()
    short.mainClips = [videoClip(0, 2), videoClip(2, 2)]
    var shortIDs = AIShortIDs(state: short)
    report = transition(.crossFade, 3, after: 0, in: &short, ids: &shortIDs)
    checkEqual(report["seams"]?.arrayValue?.first?["duration"]?.doubleValue, 0.8, "clamped to what fits between the two clips")
    checkEqual(report["seams"]?.arrayValue?.first?["shortened_from"]?.doubleValue, 3, "says what was asked")

    // all=true：太短的那条缝（0.1 秒的一段）说做不出来；藏起来的段说看不见。
    var mixed = TimelineState()
    mixed.mainClips = [videoClip(0, 4), videoClip(4, 0.1), videoClip(4.1, 4), videoClip(8.1, 4)]
    mixed.mainClips[3].isHidden = true
    var mixedIDs = AIShortIDs(state: mixed)
    let changed = (try? AITimelineEdits.setTransition(.crossFade, duration: 0.5, after: nil, all: true, in: &mixed)) ?? []
    let seams = changed.compactMap { id in mixed.mainClips.firstIndex { $0.id == id } }.sorted()
    mixedIDs = AIShortIDs(state: mixed)
    let entries = AITransitionReport.json(kind: .crossFade, seams: seams, in: mixed, asked: 0.5, ids: mixedIDs)["seams"]?.arrayValue ?? []
    checkEqual(entries.count, 3, "all=true reports every cut it touched")
    check(entries.first?["not_shown"]?.stringValue?.contains("too short") == true, "a clip too short for a transition is said so")
    check(entries.last?["not_shown"]?.stringValue?.contains("hidden") == true, "a hidden clip's transition is said not to show")

    // type none：只说拿掉了哪条缝。
    report = transition(.none, nil, after: 0, in: &roomy, ids: &roomyIDs)
    let removed = report["seams"]?.arrayValue?.first
    check(removed?["cut"] != nil && removed?["duration"] == nil, "removing a transition reports only the cut")
}

/// 照 set_transition 那样设一条缝，再按设完的状态出结果。
private func transition(
    _ kind: ClipTransition, _ seconds: Double?, after index: Int, in state: inout TimelineState, ids: inout AIShortIDs
) -> JSONValue {
    let id = state.mainClips[index].id
    _ = try? AITimelineEdits.setTransition(kind, duration: seconds, after: id, all: false, in: &state)
    ids = AIShortIDs(state: state)
    return AITransitionReport.json(kind: kind, seams: [index], in: state, asked: seconds, ids: ids)
}

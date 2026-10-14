import Foundation
import SrtFlowMCPKit

// MARK: - set_transition 的结果：每条缝上的转场实际成了什么样（纯值）
//
// 管什么：AI 设完转场，回给它每条缝放在哪、实际多长（被两段的长度夹短了要说）、余料不够时首尾帧定格补了多少
// （成片里那一截是静止的画面）、做不出来的说为什么。数都从渲染用的那几个函数来（`transitionWindow`、
// `transitionExtension`，docs/architecture/transition-handles.md），不另算一份：AI 看到的就是预览和成片里的样子。
// 不管什么：设转场本身（AITimelineEdits.setTransition）、提交（AITimelineTools）。
//
// 由来（docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 1 条）：以前只回 {"cuts": 1}，AI 不知道
// 转场落在哪、是不是被夹短了、有没有定格，只好再 look 一遍去猜。

enum AITransitionReport {
    /// 设完之后的结果。`seams`：设过的缝（出场段在 V1 上的下标，按时间排）；`asked`：AI 给的秒数（没给是 nil）。
    static func json(kind: ClipTransition, seams: [Int], in state: TimelineState, asked: Double?, ids: AIShortIDs) -> JSONValue {
        let entries: [JSONValue] = []  // reverse check: report only the count
        var result: [String: JSONValue] = [
            "type": .string(kind.rawValue),
            "cuts": .number(Double(seams.count)),
            "seams": .array(entries)
        ]
        if entries.contains(where: { $0["holds_last_frame"] != nil || $0["holds_first_frame"] != nil }) {
            result["note"] = """
                holds_last_frame / holds_first_frame: there is not enough footage beyond the cut, so that clip's last or first \
                frame is frozen for that long inside the transition (a still picture). To avoid it, trim the clips so footage \
                is left beyond the cut, or use blackFade, which needs none.
                """
        }
        return .object(result)
    }

    /// 一条缝。
    static func seam(afterMainIndex index: Int, kind: ClipTransition, in state: TimelineState, asked: Double?, ids: AIShortIDs) -> JSONValue {
        guard index >= 0, index + 1 < state.mainClips.count else { return .object([:]) }
        let outgoing = state.mainClips[index]
        let incoming = state.mainClips[index + 1]
        var entry: [String: JSONValue] = [
            "after": .string(ids.short(outgoing.id)),
            "cut": AIFormat.seconds(outgoing.timelineEnd)
        ]
        guard kind != .none else { return .object(entry) }
        guard let window = state.transitionWindow(afterMainIndex: index) else {
            // 只有 all=true 会走到这里（点名的那条缝不够长时 setTransition 直接报错）。
            entry["not_shown"] = "one of the two clips is too short for a transition"
            return .object(entry)
        }
        entry["from"] = AIFormat.seconds(window.start)
        entry["to"] = AIFormat.seconds(window.start + window.duration)
        entry["duration"] = AIFormat.seconds(window.duration)
        if let asked, asked - window.duration > 0.01 {
            entry["shortened_from"] = AIFormat.seconds(asked)
        }
        if outgoing.isHidden || incoming.isHidden {
            entry["not_shown"] = "one of the two clips is hidden; the transition comes back when it is shown"
            return .object(entry)
        }
        // 首尾相接、要两段同时在画面上的那几种：余料不够的那一截用首尾帧定格补（压黑原地两道渐变，不借料）。
        if TimelineState.needsHandles(outgoing: outgoing, incoming: incoming), !TimelineState.rendersAsDipInPlace(kind) {
            let plan = TimelineState.transitionExtension(outgoing: outgoing, incoming: incoming, duration: window.duration)
            if plan.holdTail > 0.005 { entry["holds_last_frame"] = AIFormat.seconds(plan.holdTail) }
            if plan.holdHead > 0.005 { entry["holds_first_frame"] = AIFormat.seconds(plan.holdHead) }
        }
        return .object(entry)
    }
}

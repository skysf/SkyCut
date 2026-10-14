import Foundation
import SrtFlowCore

// MARK: - 联动：生成的字幕句跟着它的那段声音走（声音不在主轨上时）
//
// 管什么：一句原文字幕是从哪一段声音里生成的（`CueMeta.provenance.clipID`：转写和配音都记），那一段**不在主轨上**（配音、音频轨上的采访、
// 上层轨的视频）时：段挪了、裁了、变了速，字幕两头各自按它在素材里的那一刻换算（`LinkageCueFollow`，同主轨那条：裁掉的那截收掉、
// 变速跟着伸缩；说的话剩不到一半就留在原地、报出来）；段被真删（`deletesContent`）字幕一起删，别的操作让段没了（剪切粘贴之外的情形少见）
// 字幕留着。字幕压着的不是这段声音（被挪开了）时照以前的算法：开头那一刻换算过去、时长不变。
// 主轨上的段不归这里管：压在主轨上的东西跟着画面走（`TimelineLinkage` 的老规矩），两条规矩不叠；这次操作碰过的字幕（包括被主轨那条挪过的）不再碰。
// 联动开关关着时不跟（调用方 `TimelineLinkage.follow` 只在开着时被调）。
// 由来：2026-10-06 盲测，AI 挪了配音段，字幕留在原地，只好一句句再挪（docs/bugfixes/2026-10-14-voiceover-subtitles-stay-behind.md）。
// 不管什么：译文轨（两条轨独立：译文没有来源段，不跟着原文挪）；被分割之后右半段的字幕（来源记的还是左半段的 id，跟着左半段）。

enum CaptionSourceFollow {
    struct Plan: Equatable {
        /// 字幕 id → 新的时间（两头各自换算过的）。
        var timings: [UUID: SubtitleTrackEditing.Timing] = [:]
        var deletes: Set<UUID> = []
        /// 收短了的（底下的声音被裁掉一截）、说的话大半没了留在原地的：报给 AI。
        var shortened: Set<UUID> = []
        var left: Set<UUID> = []

        var isEmpty: Bool { timings.isEmpty && deletes.isEmpty }
    }

    static let epsilon = 0.000_5

    /// 这次改动（`before` → `after`）里哪些字幕要跟着它的来源段挪 / 删。
    static func plan(from before: TimelineState, to after: TimelineState, deletesContent: Bool) -> Plan {
        guard let meta = before.subtitleCompanion?.cueMeta, !meta.isEmpty else { return Plan() }
        let oldCues = Dictionary(before.subtitleCues(of: .original).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = Plan()
        for cue in after.subtitleCues(of: .original) {
            // 这次碰过的不碰：只看时间（改了别的句子、字幕表会重新编号，编号变了不算碰过这一句）。
            guard let old = oldCues[cue.id], old.start == cue.start, old.end == cue.end,
                  let hostID = meta[cue.id]?.provenance?.clipID,
                  let location = before.location(of: hostID), location.track != .main,
                  let host = before.clip(with: hostID) else { continue }
            guard let moved = after.clip(with: hostID) else {
                if deletesContent { plan.deletes.insert(cue.id) } else { plan.left.insert(cue.id) }
                continue
            }
            let outcome = LinkageCueFollow.outcome(
                old, speech: LinkageCueFollow.speech(of: old, originals: oldCues, links: [:]),
                hosts: [TimelineLinkage.Piece(host)], survivors: { _ in [TimelineLinkage.Piece(moved)] },
                deletesContent: deletesContent,
                fallback: {
                    // 字幕开头对着素材的哪一秒，按段改过之后的位置换回时间线。
                    let anchor = host.sourceStart + (old.start - host.timelineStart) * max(0.05, host.speed)
                    let start = moved.timelineStart + (anchor - moved.sourceStart) / max(0.05, moved.speed)
                    return abs(start - old.start) > epsilon ? .move(by: start - old.start) : .stay
                }
            )
            switch outcome {
            case .stay: break
            case .delete: plan.deletes.insert(cue.id)
            case .leftBehind: plan.left.insert(cue.id)
            case .retime(let timing, let shortened):
                plan.timings[cue.id] = timing
                if shortened { plan.shortened.insert(cue.id) }
            }
        }
        return plan
    }

    /// 照计划写进去。
    static func apply(_ plan: Plan, to state: inout TimelineState) {
        guard !plan.isEmpty else { return }
        state.editSubtitleTracks { original, companion in
            SubtitleTrackEditing.removeCues(ids: plan.deletes, original: &original, companion: &companion)
            SubtitleTrackEditing.setTimings(plan.timings, original: &original, companion: &companion)
        }
    }
}

import Foundation
import SrtFlowCore

// MARK: - 联动：生成的字幕句跟着它的那段声音走（声音不在主轨上时）
//
// 管什么：一句原文字幕是从哪一段声音里生成的（`CueMeta.provenance.clipID`：转写和配音都记），那一段**不在主轨上**（配音、音频轨上的采访、
// 上层轨的视频）时：段挪了、裁了、变了速，字幕两头各自按它在素材里的那一刻换算（`LinkageCueFollow`，同主轨那条：裁掉的那截收掉、
// 变速跟着伸缩；说的话剩不到一半就删，裁掉的也删）；段被真删（`deletesContent`）字幕一起删，别的操作让段整个没了（剪切粘贴之外的情形少见）
// 字幕留着、报出来。字幕压着的不是这段声音（被挪开了）时照以前的算法：开头那一刻换算过去、时长不变。
// 主轨上的段不归这里管：压在主轨上的东西跟着画面走（`TimelineLinkage` 的老规矩），两条规矩不叠；这次操作碰过的字幕（包括被主轨那条挪过的）不再碰。
// Which subtitles are this file's and which are the picture's is one map, `voices` (UI-3, 2026-11-18): the picture rule used
// to run first on every subtitle above V1, so a new window on a screen recording shortened or deleted its narration's subtitles.
// A translation goes with the sound of the original it was translated from (its words are that sound's).
// 段换了声音文件（同 id、入点变了）按改之前的素材和入点记账（`Piece.rebased`）：字幕原地不动。
// 联动开关关着时不跟（调用方 `TimelineLinkage.follow` 只在开着时被调）。
// 由来：2026-10-06 盲测，AI 挪了配音段，字幕留在原地，只好一句句再挪（docs/bugfixes/2026-10-14-voiceover-subtitles-stay-behind.md）。
// 不管什么：被分割之后右半段的字幕（来源记的还是左半段的 id，跟着左半段）。

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

    /// The clip off V1 whose words a subtitle shows; `sitsOnIt`: the subtitle overlaps that clip on the timeline.
    struct Voice: Equatable {
        let clip: UUID
        let sitsOnIt: Bool
    }

    /// Which subtitles show the words of a sound off V1 (UI-3, 2026-11-18): original cues generated from a clip not on the main
    /// track (`provenance.clipID`: narration, an interview on an audio track, an upper-track video), and translations sitting on
    /// the clip all their originals came from (same words). All of them follow that sound (`plan`). The ones sitting on it are
    /// that sound's alone: `TimelineLinkage.followMain` keeps them out of the picture rule and a V1 drag carries them only with
    /// the sound (`TimelineLinkage.attachments`) — one map for the three places, so the rules neither overlap nor leave a gap.
    /// A subtitle away from the clip its source names (the right half of a split narration still names the left half; a sound
    /// moved while linkage was off) keeps following the picture as before: the named clip does not hold its words any more.
    static func voices(in state: TimelineState) -> [UUID: Voice] {
        guard let companion = state.subtitleCompanion, !companion.cueMeta.isEmpty else { return [:] }
        let sounds = Dictionary(state.laneClips.map { ($0.id, $0.span) }, uniquingKeysWith: { first, _ in first })
        func sits(_ cue: SubtitleCue, on clip: UUID) -> Bool {
            guard let span = sounds[clip] else { return false }
            return cue.start < span.end - epsilon && span.start < cue.end - epsilon
        }
        var voices: [UUID: Voice] = [:]
        for cue in state.subtitleCues(of: .original) {
            guard let clip = companion.cueMeta[cue.id]?.provenance?.clipID, sounds[clip] != nil else { continue }
            voices[cue.id] = Voice(clip: clip, sitsOnIt: sits(cue, on: clip))
        }
        guard !voices.isEmpty else { return [:] }
        for cue in state.subtitleCues(of: .translation) {
            guard let sources = companion.translationLinks[cue.id]?.sourceIDs, !sources.isEmpty else { continue }
            let clips = Set(sources.map { voices[$0]?.clip })
            guard clips.count == 1, let only = clips.first, let clip = only, sits(cue, on: clip) else { continue }
            voices[cue.id] = Voice(clip: clip, sitsOnIt: true)
        }
        return voices
    }

    /// 这次改动（`before` → `after`）里哪些字幕要跟着它的来源段挪 / 删。
    static func plan(from before: TimelineState, to after: TimelineState, deletesContent: Bool) -> Plan {
        let voices = voices(in: before)
        guard !voices.isEmpty else { return Plan() }
        let oldCues = Dictionary(before.allSubtitleCues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(before.subtitleCues(of: .original).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let links = before.subtitleCompanion?.translationLinks ?? [:]
        var plan = Plan()
        for cue in after.allSubtitleCues {
            // 这次碰过的不碰：只看时间（改了别的句子、字幕表会重新编号，编号变了不算碰过这一句）。
            guard let hostID = voices[cue.id]?.clip, let old = oldCues[cue.id], old.start == cue.start, old.end == cue.end,
                  let host = before.clip(with: hostID) else { continue }
            guard let moved = after.clip(with: hostID) else {
                if deletesContent { plan.deletes.insert(cue.id) } else { plan.left.insert(cue.id) }
                continue
            }
            // 换了声音文件的（edit_clip 换文件）按改之前的素材和入点记账（`Piece.rebased`，同主轨那条）：字幕不跟着新入点跑。
            let was = TimelineLinkage.Piece(host)
            let now = TimelineLinkage.Piece(moved).rebased(onto: was)
            let outcome = LinkageCueFollow.outcome(
                old, speech: LinkageCueFollow.speech(of: old, originals: originals, links: links),
                hosts: [was], survivors: { _ in [now] },
                deletesContent: deletesContent,
                fallback: {
                    // 字幕开头对着素材的哪一秒，按段改过之后的位置换回时间线。
                    let start = now.time(atSource: was.source(at: old.start))
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

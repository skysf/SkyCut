import Foundation
import SrtFlowCore

// MARK: - edit_subtitles：一批字幕改动（纯值）
//
// 管什么：把 AI 给的「改哪几句、加哪几句、删哪几句、整轨查找替换、整轨去标点」读成类型、先全部验过（时间倒过来的、
// id 不是字幕的、正则编不过，一句都不改就报错），再用 `SubtitleTrackEditing` 那份两轨合同一次改完。
// 顺序：改字 / 改时间 → 加句 → 合并 → 查找替换 → 去标点 → 删句（批量的两样套在那一刻轨上的每一句，新加的也算）。
// 自检够得着（scripts/check-mcp.sh）。
// 不管什么：一条查找替换怎么算（AISubtitleReplacement）、提交和给用户看（AISubtitleTools.edit）。

struct AISubtitleEdits {
    struct Change {
        var id: UUID
        var text: String?
        var start: Double?
        var end: Double?
    }

    struct Addition {
        var track: SubtitleTrack
        var start: Double
        var end: Double
        var text: String
    }

    var changes: [Change] = []
    var additions: [Addition] = []
    var deletions: Set<UUID> = []
    /// 要并成一句的几组（每组两句以上、同一条轨、按顺序）：走界面「合并」那份合同（`SubtitleTrackEditing.mergeCues`），
    /// 逐词时间拼起来。改字把两句抄成一句会把挪进来的词的时间丢掉（2026-09-29 婚礼工程 BUG-06）。
    var merges: [[UUID]] = []
    /// 批量改字（2026-10-15 用户转来的反馈：去标点只能一句一句改）：查找替换（`AISubtitleReplacement`）和去标点
    /// （`SubtitlePunctuation.strip`：生成字幕落字时那一份规则，用户手打的字只在 AI 点名时才去）。都走 `setText`，
    /// 没改的字保住词的时间（逐词高亮）。
    var replacements: [AISubtitleReplacement] = []
    var stripsPunctuation = false

    var isEmpty: Bool {
        changes.isEmpty && additions.isEmpty && deletions.isEmpty && merges.isEmpty && replacements.isEmpty && !stripsPunctuation
    }

    /// 改完之后给 AI 看的账。
    struct Outcome {
        var created: [UUID] = []
        var merged: [UUID] = []
        /// 查找替换 / 去标点改到的句子；其中改成空句的另列出来，AI 好决定删不删。
        var rewritten: [UUID] = []
        var emptied: [UUID] = []
    }

    static func parse(_ args: AIToolArguments, ids: AIShortIDs, in state: TimelineState) throws -> AISubtitleEdits {
        var edits = AISubtitleEdits()
        for (index, item) in (try args.array("changes") ?? []).enumerated() {
            let entry = AIToolArguments(item)
            let id = try ids.resolve(try entry.requiredString("id"))
            guard let cue = state.subtitleCue(id) else { throw AIToolError("changes[\(index)]: that id is not a subtitle line.") }
            let change = Change(id: id, text: try entry.string("text"), start: try entry.double("start"), end: try entry.double("end"))
            guard (change.end ?? cue.end) > (change.start ?? cue.start) else {
                throw AIToolError("changes[\(index)]: end must be after start.")
            }
            edits.changes.append(change)
        }
        for (index, item) in (try args.array("add") ?? []).enumerated() {
            let entry = AIToolArguments(item)
            let track: SubtitleTrack = try entry.choice("track", from: ["original", "translation"]) == "translation"
                ? .translation : .original
            let start = max(0, try entry.requiredDouble("start"))
            let end = try entry.requiredDouble("end")
            guard end > start else { throw AIToolError("add[\(index)]: end must be after start.") }
            edits.additions.append(Addition(track: track, start: start, end: end, text: try entry.string("text") ?? ""))
        }
        for text in try args.stringArray("delete") ?? [] {
            let id = try ids.resolve(text)
            guard state.subtitleCue(id) != nil else { throw AIToolError("delete: \(text) is not a subtitle line.") }
            edits.deletions.insert(id)
        }
        for (index, item) in (try args.array("merge") ?? []).enumerated() {
            guard case .array(let members) = item, members.count >= 2 else {
                throw AIToolError("merge[\(index)]: give two or more line ids to join.")
            }
            var group: [UUID] = []
            var tracks: Set<SubtitleTrack> = []
            for member in members {
                guard let text = member.stringValue else { throw AIToolError("merge[\(index)]: ids must be strings.") }
                let id = try ids.resolve(text)
                guard let track = state.subtitleTrack(of: id) else { throw AIToolError("merge[\(index)]: \(text) is not a subtitle line.") }
                tracks.insert(track)
                if !group.contains(id) { group.append(id) }
            }
            guard tracks.count == 1 else { throw AIToolError("merge[\(index)]: all lines must be on the same track (original or translation).") }
            guard group.count >= 2 else { throw AIToolError("merge[\(index)]: give two or more different lines.") }
            edits.merges.append(group)
        }
        for (index, item) in (try args.array("replace") ?? []).enumerated() {
            edits.replacements.append(try AISubtitleReplacement(AIToolArguments(item), index: index))
        }
        edits.stripsPunctuation = try args.bool("strip_punctuation") ?? false
        return edits
    }

    /// 一次改完，返回新加的那几句的 id、每组合并后留下的那句的 id、批量改到的句子。还没有字幕轨时就地建一条原文轨（同界面上的「+」）。
    func apply(to state: inout TimelineState) -> Outcome {
        var outcome = Outcome()
        state.editSubtitleTracks(creatingOriginal: !additions.isEmpty) { original, companion in
            for change in changes {
                if let text = change.text {
                    SubtitleTrackEditing.setText(id: change.id, text: text, original: &original, companion: &companion)
                }
                if change.start != nil || change.end != nil {
                    let cue = original.cues.first { $0.id == change.id }
                        ?? companion.translation?.cues.first { $0.id == change.id }
                    guard let cue else { continue }
                    SubtitleTrackEditing.setTime(
                        id: change.id, start: max(0, change.start ?? cue.start), end: change.end ?? cue.end,
                        original: &original, companion: &companion
                    )
                }
            }
            for addition in additions {
                let cue = SubtitleCue(id: UUID(), start: addition.start, end: addition.end, text: addition.text)
                if let id = SubtitleTrackEditing.insertCue(cue, into: addition.track, original: &original, companion: &companion) {
                    outcome.created.append(id)
                }
            }
            for group in merges {
                // 留下的是文档顺序里最靠前的那句（mergeCues 的合同）。
                let order = original.cues.map(\.id) + (companion.translation?.cues.map(\.id) ?? [])
                guard let kept = order.first(where: { group.contains($0) }),
                      SubtitleTrackEditing.mergeCues(ids: Set(group), original: &original, companion: &companion)
                else { continue }
                outcome.merged.append(kept)
            }
            for replacement in replacements {
                Self.rewrite(&original, &companion, on: replacement.track, into: &outcome) { replacement.apply(to: $0) }
            }
            if stripsPunctuation {
                Self.rewrite(&original, &companion, on: nil, into: &outcome) { SubtitlePunctuation.strip($0) }
            }
            if !deletions.isEmpty {
                SubtitleTrackEditing.removeCues(ids: deletions, original: &original, companion: &companion)
            }
        }
        return outcome
    }

    /// 把 `transform` 套在 `track`（nil = 两条轨）此刻的每一句上，变了的走 `setText`（词的时间跟着挪）、记进账。
    private static func rewrite(
        _ original: inout SubtitleDocumentModel, _ companion: inout SubtitleCompanion, on track: SubtitleTrack?,
        into outcome: inout Outcome, _ transform: (String) -> String
    ) {
        var cues: [SubtitleCue] = []
        if track != .translation { cues += original.cues }
        if track != .original { cues += companion.translation?.cues ?? [] }
        for cue in cues {
            let text = transform(cue.text)
            guard text != cue.text else { continue }
            SubtitleTrackEditing.setText(id: cue.id, text: text, original: &original, companion: &companion)
            if !outcome.rewritten.contains(cue.id) { outcome.rewritten.append(cue.id) }
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if empty, !outcome.emptied.contains(cue.id) { outcome.emptied.append(cue.id) }
            if !empty { outcome.emptied.removeAll { $0 == cue.id } }
        }
    }
}

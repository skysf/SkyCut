import Foundation
import SrtFlowMCPKit

// MARK: - 联动的结果怎么报给 AI
//
// 管什么：一次改动之后联动（docs/architecture/timeline-linkage.md）挪了几样、删了几样，在工具结果里带一笔 `linkage`：
// AI 看得见「删了一段，它上面的三句字幕也没了、后面的两段文字跟着前移了」，不用再 get_timeline 对一遍。
// 字幕另报两样（规矩 12，2026-10-15）：底下有画面被剪掉、收短了的（字里可能还留着剪掉的词，`shortened_subtitles`），
// 和说的话大半被裁掉、又不是真删所以留在原地的（`left_subtitles`）—— 人在时间线上一眼看得见，AI 只能从这里知道。
// 什么都没动就不带（开关关着、或者这次没碰主轨的画面）。
// 不管什么：联动本身（`TimelineLinkage`）、开关（`get_timeline` 的 `linkage` 字段报着）。

enum AILinkageReport {
    /// `ids`：改完之后的工程的短 id（收短了、留在原地的字幕都还在）。
    static func json(_ report: TimelineLinkage.Report, ids: AIShortIDs) -> JSONValue? {
        guard !report.isEmpty else { return nil }
        var entry: [String: JSONValue] = [:]
        if report.moved > 0 { entry["moved"] = .number(Double(report.moved)) }
        if report.deleted > 0 { entry["deleted"] = .number(Double(report.deleted)) }
        var notes = ["Linkage is on: items on other tracks followed the V1 clips they sit on."]
        if !report.shortenedCues.isEmpty {
            entry["shortened_subtitles"] = list(report.shortenedCues, ids)
            notes.append("Shortened subtitles lost part of the speech under them; their text may still have the cut words: check with get_subtitles.")
        }
        if !report.leftCues.isEmpty {
            entry["left_subtitles"] = list(report.leftCues, ids)
            notes.append("Left subtitles sat mostly on picture that was trimmed away, so they stayed where they were: delete them with delete_items if they no longer belong.")
        }
        entry["note"] = .string(notes.joined(separator: " "))
        return .object(entry)
    }

    private static func list(_ cues: Set<UUID>, _ ids: AIShortIDs) -> JSONValue {
        .array(cues.map { ids.short($0) }.sorted().map { .string($0) })
    }

    /// 磁吸这次把 V1 排紧挪了几段（结果里的 `magnet`）：AI 没动 V1、V1 却变了的时候，它要知道是这个工程的磁吸开着
    ///（2026-10-02 南极工程：AI 只看到「联动挪了 97 样」，查了半天才发现整条 V1 被合拢了）。
    static func magnet(_ report: TimelineLinkage.Report) -> JSONValue? {
        guard report.magnetPacked > 0 else { return nil }
        return .object([
            "moved": .number(Double(report.magnetPacked)),
            "note": .string("The V1 magnet is on in this project: V1 clips were closed up after this edit."),
        ])
    }
}

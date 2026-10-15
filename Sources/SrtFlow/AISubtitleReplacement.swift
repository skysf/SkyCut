import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - edit_subtitles 的 replace：一条查找替换（纯值）
//
// 管什么：AI 给的一条 `replace`（find / with / regex / track）读成类型、先验过（find 不许空、with 必填、正则编不过当场报错），
// 以及它套在一句字幕的文字上得到什么：字面匹配区分大小写；regex=true 时 find 是 ICU 正则（NSRegularExpression），
// with 是模板、能写 $1。2026-10-15 用户转来的反馈：去标点只能一句一句改字（37 + 6 行），要一个批量改字的办法。
// 不管什么：改哪几句、怎么落账（AISubtitleEdits → SubtitleTrackEditing.setText，没改的字保住词的时间）。

struct AISubtitleReplacement {
    var find: String
    var with: String
    var regex: NSRegularExpression?
    /// nil = 两条轨都改。
    var track: SubtitleTrack?

    init(_ entry: AIToolArguments, index: Int) throws {
        // 不用 requiredString：它把空白也当没给，而 find 可以是几个空格、with 可以是空（删掉匹配的）。
        guard let find = try entry.string("find"), !find.isEmpty else { throw AIToolError("replace[\(index)]: find is required.") }
        self.find = find
        guard let with = try entry.string("with") else {
            throw AIToolError("replace[\(index)]: with is required (an empty string removes the match).")
        }
        self.with = with
        if try entry.bool("regex") == true {
            guard let compiled = try? NSRegularExpression(pattern: find) else {
                throw AIToolError("replace[\(index)]: find is not a valid regular expression.")
            }
            regex = compiled
        }
        switch try entry.choice("track", from: ["original", "translation", "both"]) {
        case "original": track = .original
        case "translation": track = .translation
        default: track = nil
        }
    }

    func applies(to track: SubtitleTrack) -> Bool {
        self.track == nil || self.track == track
    }

    /// 这一句改完是什么；没碰到就原样。
    func apply(to text: String) -> String {
        guard let regex else { return text.replacingOccurrences(of: find, with: with) }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
    }
}

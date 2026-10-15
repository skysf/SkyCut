import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// edit_subtitles 的批量改字（2026-10-15 用户转来的反馈：去标点只能一句一句改字，37 + 6 行）：
// replace（字面 / 正则、限定轨、find 不许空、with 必填、坏正则当场报错）、strip_punctuation（生成那一份规则套在每一句上），
// 两样都走 setText —— 没改的字保住词的时间；顺序在改字 / 加句 / 合并之后、删句之前（新加的那句也去标点）；
// 改到几句、掏空了哪几句报出来。编法见 scripts/check-mcp.sh。

func runSubtitleBulkChecks() {
    subtitleReplaceChecks()
    subtitleStripChecks()
}

private func bulkState() -> (state: TimelineState, first: SubtitleCue, second: SubtitleCue, translated: SubtitleCue) {
    var state = TimelineState()
    var first = SubtitleCue(id: UUID(), start: 0, end: 2, text: "I found, a love.")
    first.words = [SubtitleCueWord(location: 0, length: 1, start: 0, end: 0.3), SubtitleCueWord(location: 2, length: 5, start: 0.3, end: 0.9),
                   SubtitleCueWord(location: 9, length: 1, start: 0.9, end: 1.0), SubtitleCueWord(location: 11, length: 4, start: 1.0, end: 1.58)]
    let second = SubtitleCue(id: UUID(), start: 3, end: 5, text: "The colour is 50% off, bye.")
    var document = SubtitleDocumentModel(format: .srt)
    document.cues = [first, second]
    state.subtitle = document
    let translated = SubtitleCue(id: UUID(), start: 0, end: 2, text: "我找到了，一份爱。")
    var translation = SubtitleDocumentModel(format: .srt)
    translation.cues = [translated]
    var companion = state.subtitleCompanion ?? SubtitleCompanion()
    companion.translation = translation
    state.subtitleCompanion = companion
    return (state, first, second, translated)
}

private func subtitleReplaceChecks() {
    var (state, first, second, translated) = bulkState()
    let ids = AIShortIDs(state: state)
    let edits = try? AISubtitleEdits.parse(args([
        "replace": [
            ["find": "colour", "with": "color", "track": "original"],
            ["find": "(\\d+)%", "with": "$1 percent", "regex": true],
            ["find": "一份", "with": "", "track": "translation"]
        ]
    ]), ids: ids, in: state)
    check(edits?.isEmpty == false, "replace alone is an edit")
    let outcome = edits?.apply(to: &state) ?? .init()
    let cues = state.subtitleCues(of: .original)
    checkEqual(cues.map(\.text), ["I found, a love.", "The color is 50 percent off, bye."], "literal and regex replacements land; untouched lines stay")
    checkEqual(state.subtitleCues(of: .translation).map(\.text), ["我找到了，爱。"], "a replacement limited to the translation only touches it")
    checkEqual(Set(outcome.rewritten), Set([second.id, translated.id]), "the lines that changed are reported once each")
    check(outcome.emptied.isEmpty, "nothing was emptied")
    check(outcome.created.isEmpty && outcome.merged.isEmpty, "no lines created or merged")
    _ = first

    // 替换成空把一句掏空：报出来，句子留着（删不删 AI 定）。
    var (again, _, lone, _) = bulkState()
    let emptying = try? AISubtitleEdits.parse(args(["replace": [["find": "The colour is 50% off, bye.", "with": ""]]]), ids: AIShortIDs(state: again), in: again)
    let emptied = emptying?.apply(to: &again) ?? .init()
    checkEqual(emptied.emptied, [lone.id], "a line replaced with nothing is reported as emptied")
    checkEqual(again.subtitleCues(of: .original).count, 2, "…but not deleted")

    let (fresh, _, _, _) = bulkState()
    let freshIDs = AIShortIDs(state: fresh)
    checkThrows("an empty find is refused") { _ = try AISubtitleEdits.parse(args(["replace": [["find": "", "with": "x"]]]), ids: freshIDs, in: fresh) }
    checkThrows("with is required (an accidental omission would delete text)") {
        _ = try AISubtitleEdits.parse(args(["replace": [["find": "a"]]]), ids: freshIDs, in: fresh)
    }
    checkThrows("a broken regular expression is refused before anything changes") {
        _ = try AISubtitleEdits.parse(args(["replace": [["find": "(", "with": "", "regex": true]]]), ids: freshIDs, in: fresh)
    }
    checkThrows("an unknown track is refused") {
        _ = try AISubtitleEdits.parse(args(["replace": [["find": "a", "with": "b", "track": "bilingual"]]]), ids: freshIDs, in: fresh)
    }
}

private func subtitleStripChecks() {
    var (state, first, second, translated) = bulkState()
    let ids = AIShortIDs(state: state)
    let edits = try? AISubtitleEdits.parse(args([
        "strip_punctuation": true,
        "add": [["start": 6, "end": 7, "text": "Hi, there."]]
    ]), ids: ids, in: state)
    check(edits?.isEmpty == false, "strip_punctuation alone is an edit")
    let outcome = edits?.apply(to: &state) ?? .init()
    let cues = state.subtitleCues(of: .original)
    checkEqual(cues.map(\.text), ["I found a love", "The colour is 50% off bye", "Hi there"],
               "pause punctuation goes: a space mid-line, nothing at the end; the line added in the same call is stripped too")
    checkEqual(state.subtitleCues(of: .translation).map(\.text), ["我找到了 一份爱"], "Chinese punctuation on the translation goes the same way")
    checkEqual(Set(outcome.rewritten), Set([first.id, second.id, translated.id] + outcome.created), "every changed line is reported, the new one included")
    let words = cues.first?.words ?? []
    checkEqual(words.count, 4, "stripping keeps every word time")
    checkEqual(words.last?.location, 10, "\"love\" moved left with the comma gone")
    check(abs((words.last?.start ?? 0) - 1.0) < 1e-9 && abs((words.last?.end ?? 0) - 1.58) < 1e-9, "…and keeps its moment")
    checkEqual(words[1].location, 2, "\"found\" is where it was")
    check(outcome.emptied.isEmpty, "no line was emptied")

    // 替换在去标点之前跑：先把 bye 换掉，再去标点，行尾的逗号也没了。
    var (ordered, _, _, _) = bulkState()
    let both = try? AISubtitleEdits.parse(args([
        "replace": [["find": "bye", "with": ""]], "strip_punctuation": true
    ]), ids: AIShortIDs(state: ordered), in: ordered)
    _ = both?.apply(to: &ordered)
    checkEqual(ordered.subtitleCues(of: .original).last?.text, "The colour is 50% off", "replace runs first, then the stripping cleans the line end")
}

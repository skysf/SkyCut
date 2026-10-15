import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// export_subtitles 写哪几份、叫什么（AISubtitleFiles，2026-10-15）：both = 有句子的每一条轨，点名的轨没有句子就说该先用哪个工具；
// `<名字>.<语言>.<格式>`（和导出面板「高级」同一个起名函数）；两份同一个标签时译文那份叫 translation；撞名整组加编号、从不覆盖；
// 格式词表都是 SubtitleFormat 的扩展名。语言标签（SubtitleFileLanguage，导出面板同一份）：按这条轨现在的文字判 → 判不出来用工程记的 →
// 都没有才省略；文字先于记录（docs/bugfixes/2026-10-15-subtitle-file-export-missing-language-tag.md：手写的译文、导入的 .srt 工程里没记语言，
// 只读记录就导出成不带标签的 promo.vtt）。编法见 scripts/check-mcp.sh。

func runSubtitleFileChecks() {
    let folder = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/exports")
    checkEqual(try? AISubtitleFiles.tracks("both", available: [.original, .translation]), [.original, .translation],
               "both: every track that has lines")
    checkEqual(try? AISubtitleFiles.tracks("both", available: [.original]), [.original], "both without a translation: just the original")
    checkThrows("asking for a translation the project does not have says so") {
        _ = try AISubtitleFiles.tracks("translation", available: [.original])
    }
    checkThrows("no subtitles at all says so") { _ = try AISubtitleFiles.tracks("both", available: []) }

    func names(
        _ tracks: [SubtitleTrack], _ format: SubtitleFormat, _ source: String?, _ target: String?, taken: Set<String> = []
    ) -> [String] {
        AISubtitleFiles.targets(tracks, stem: "Talk", folder: folder, format: format, sourceLanguage: source, targetLanguage: target) {
            taken.contains($0.lastPathComponent)
        }.map(\.url.lastPathComponent)
    }
    checkEqual(names([.original, .translation], .srt, "en", "zh-Hans"), ["Talk.en.srt", "Talk.zh-Hans.srt"],
               "named like the export panel: <name>.<language>.srt, next to a Talk.mp4")
    checkEqual(names([.original, .translation], .vtt, nil, nil), ["Talk.vtt", "Talk.translation.vtt"],
               "no language tags: the translation does not take the original's name")
    checkEqual(names([.translation], .srt, "en", "en"), ["Talk.en.srt"], "one track alone keeps its own tag")
    checkEqual(names([.original, .translation], .srt, "en", "zh-Hans", taken: ["Talk.zh-Hans.srt", "Talk 2.en.srt"]),
               ["Talk 3.en.srt", "Talk 3.zh-Hans.srt"], "a taken name: the whole set moves to the next free number, nothing is replaced")
    check(MCPVocabulary.subtitleFileFormats.allSatisfy { SubtitleFormat(rawValue: $0) != nil },
          "export_subtitles formats are SubtitleFormat extensions")
    checkEqual(AISubtitleFiles.trackChoices, ["original", "translation", "both"], "track choices")

    // 语言标签：没记语言的轨按文字判（手写的中文译文、导入的英文 .srt）；判不出来（只有数字）退回记的；都没有才省略；文字先于记录。
    let english = ["Congratulations on finishing the course", "Let's review what we learned", "Thanks for watching"]
    let chinese = ["恭喜你完成了这门课程", "我们回顾一下学到的内容", "感谢观看"]
    let numbersOnly = ["1", "2", "3"]
    typealias Inputs = SubtitleFileLanguage.Inputs
    checkEqual(SubtitleFileLanguage.tags(Inputs(original: english, translation: chinese)), SubtitleFileLanguage(source: "en", target: "zh-Hans"),
               "no recorded languages (hand-written translation, imported .srt): both tags come from the text")
    checkEqual(SubtitleFileLanguage.tags(Inputs(original: numbersOnly, translation: [], recordedSource: "en", recordedTarget: "ja")),
               SubtitleFileLanguage(source: "en", target: "ja"), "text that cannot be judged: the project's record")
    checkEqual(SubtitleFileLanguage.tags(Inputs(original: numbersOnly, translation: [])), SubtitleFileLanguage(),
               "nothing to judge and nothing recorded: no tag")
    checkEqual(SubtitleFileLanguage.tags(Inputs(original: chinese, translation: english, recordedSource: "en", recordedTarget: "zh-Hans")),
               SubtitleFileLanguage(source: "zh-Hans", target: "en"),
               "the text wins over a stale record (the AI rewrote the track), like translate_subtitles")
    // 从时间线读：写进文件的那份句子（藏起来的不算）。只有藏起来的那句是中文时，原文轨按剩下的英文判。
    var state = TimelineState()
    var original = SubtitleDocumentModel(format: .srt, cues: [])
    let hidden = SubtitleCue(index: 1, start: 0, end: 1, text: chinese[0])
    original.cues = [hidden] + english.enumerated().map { SubtitleCue(index: $0.offset + 2, start: Double($0.offset + 1), end: Double($0.offset + 2), text: $0.element) }
    state.subtitle = original
    state.subtitleCompanion = SubtitleCompanion(
        translation: SubtitleDocumentModel(format: .srt, cues: chinese.enumerated().map {
            SubtitleCue(index: $0.offset + 1, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
        }),
        hiddenCueIDs: [hidden.id]
    )
    checkEqual(SubtitleFileLanguage.tags(in: state), SubtitleFileLanguage(source: "en", target: "zh-Hans"),
               "from the timeline: judged on the lines that go into the file, hidden ones left out, nothing recorded")
    let tagged = SubtitleFileLanguage.tags(in: state)
    checkEqual(names([.original, .translation], .vtt, tagged.source, tagged.target), ["Talk.en.vtt", "Talk.zh-Hans.vtt"],
               "export_subtitles on such a project: promo.en.vtt + promo.zh-Hans.vtt, not promo.vtt")
}

import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// export_subtitles 写哪几份、叫什么（AISubtitleFiles，2026-10-15）：both = 有句子的每一条轨，点名的轨没有句子就说该先用哪个工具；
// `<名字>.<语言>.<格式>`（和导出面板「高级」同一个起名函数）；两份同一个标签时译文那份叫 translation；撞名整组加编号、从不覆盖；
// 格式词表都是 SubtitleFormat 的扩展名。编法见 scripts/check-mcp.sh。

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
}

import Foundation
import SrtFlowCore

// MARK: - export_subtitles 写哪几份、叫什么（纯值）
//
// 管什么：AI 要的轨（original / translation / both）落成哪几条有句子的轨；每条轨一份 `<名字>.<语言>.<格式>` —— 和导出面板
// 「高级」里的独立字幕文件同一个起名函数（`SubtitleExportPlanner.fileName`），和视频同名放在一起，播放器会自动挂上。
// 两条轨的语言标签一样（或者都没有）时，译文那份用 `translation` 当标签，免得两份同名、后一份盖掉前一份。
// 任何一份已经有了，就整组换成 `<名字> 2`、`<名字> 3`……：几份还是同一个名字，认得出是一套；从不覆盖（方案第 34 条）。
// 不管什么：写盘（`SubtitleExportPlanner.writeValidated`）、参数和结果（AISubtitleFileExport）。

enum AISubtitleFiles {
    struct Target: Equatable {
        var track: SubtitleTrack
        var url: URL
    }

    /// export_subtitles 的 `track` 收什么（both = 有句子的每一条轨）。
    static let trackChoices = ["original", "translation", "both"]

    /// 要写哪几条轨。点名的那条没有句子就说清楚该先用哪个工具。
    static func tracks(_ which: String, available: Set<SubtitleTrack>) throws -> [SubtitleTrack] {
        let none = "The project has no subtitles yet. Make them with generate_subtitles or edit_subtitles first."
        switch which {
        case "original":
            guard available.contains(.original) else { throw AIToolError(none) }
            return [.original]
        case "translation":
            guard available.contains(.translation) else {
                throw AIToolError("The project has no translated subtitles. Make them with translate_subtitles first.")
            }
            return [.translation]
        default:
            let tracks = SubtitleTrack.allCases.filter(available.contains)
            guard !tracks.isEmpty else { throw AIToolError(none) }
            return tracks
        }
    }

    /// 每条轨写到哪。`exists`：这个文件已经有了没有（撞了整组加编号）。
    static func targets(
        _ tracks: [SubtitleTrack], stem: String, folder: URL, format: SubtitleFormat,
        sourceLanguage: String?, targetLanguage: String?, exists: (URL) -> Bool
    ) -> [Target] {
        // 两份要是同一个标签（同一种语言、或者都不知道是什么语言），译文那份换成 translation。
        let translationTag = tracks.count > 1 && targetLanguage == sourceLanguage ? "translation" : targetLanguage
        func named(_ base: String) -> [Target] {
            tracks.map { track in
                let name = SubtitleExportPlanner.fileName(
                    base: base, choice: track == .original ? .original : .translation,
                    sourceLanguage: sourceLanguage, targetLanguage: translationTag, format: format
                )
                return Target(track: track, url: folder.appendingPathComponent(name))
            }
        }
        var base = stem
        var number = 2
        while named(base).contains(where: { exists($0.url) }) {
            base = "\(stem) \(number)"
            number += 1
        }
        return named(base)
    }
}

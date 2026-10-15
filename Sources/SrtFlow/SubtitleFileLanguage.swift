import Foundation
import SrtFlowCore

// MARK: - 字幕文件名里的语言标签（导出面板「高级」和 export_subtitles 同一份）
//
// 管什么：`<名字>.<语言>.srt` 里的 `<语言>` 从哪来。每条轨依次取：按这条轨**现在的文字**判（`AITextLanguage.dominant`）→
// 判不出来用工程记的（`SubtitleCompanion.sourceLanguage` / `targetLanguage`）→ 都没有才省略（`SubtitleExportPlanner.fileName`
// 缺标签就不写）。先按文字、再信记录，和 translate_subtitles 认原文语言同一个顺序：手写（edit_subtitles）、导入（add_clips 的 .srt）
// 的轨工程里没记语言，AI 也可能把整轨改写成别的语言而记的还是旧的（docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。
// 2026-10-15 之前只读记录：没记语言的轨导出成不带标签的 `promo.vtt`，播放器把它当成视频的默认字幕
// （docs/bugfixes/2026-10-15-subtitle-file-export-missing-language-tag.md）。
// 判出来的只用来起名，不写回工程。按写进文件的那份句子判（`subtitleDocument(for:)`：藏起来的不算）。
// 不管什么：起名本身（SrtFlowCore 的 `SubtitleExportPlanner.fileName`）、两份同一个标签时译文叫 translation（`AISubtitleFiles`）。

struct SubtitleFileLanguage: Equatable {
    /// 原文轨 / 译文轨的标签，nil = 文件名里不带。
    var source: String?
    var target: String?

    init(source: String? = nil, target: String? = nil) {
        self.source = source
        self.target = target
    }

    /// 判标签要的全部输入（纯值；界面拿它当「变没变」的键，变了才重判，不在 body 里跑语言识别）。
    struct Inputs: Equatable {
        var original: [String]
        var translation: [String]
        var recordedSource: String?
        var recordedTarget: String?

        init(original: [String], translation: [String], recordedSource: String? = nil, recordedTarget: String? = nil) {
            self.original = original
            self.translation = translation
            self.recordedSource = recordedSource
            self.recordedTarget = recordedTarget
        }

        /// 写进文件的那份句子（藏起来的不算）+ 工程记的语言。
        init(_ state: TimelineState) {
            self.init(
                original: state.subtitleDocument(for: .original)?.cues.map(\.text) ?? [],
                translation: state.subtitleDocument(for: .translation)?.cues.map(\.text) ?? [],
                recordedSource: state.subtitleCompanion?.sourceLanguage,
                recordedTarget: state.subtitleCompanion?.targetLanguage
            )
        }
    }

    /// 每条轨：按文字判 → 判不出来用记的 → 都没有才 nil。
    static func tags(_ inputs: Inputs) -> SubtitleFileLanguage {
        SubtitleFileLanguage(
            source: AITextLanguage.dominant(in: inputs.original) ?? inputs.recordedSource,
            target: AITextLanguage.dominant(in: inputs.translation) ?? inputs.recordedTarget
        )
    }

    static func tags(in state: TimelineState) -> SubtitleFileLanguage {
        tags(Inputs(state))
    }
}

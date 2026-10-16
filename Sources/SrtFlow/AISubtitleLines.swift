import Foundation
import SrtFlowCore

// AI 要几行的字幕：generate_subtitles / add_voiceover 的 `max_lines`（2026-10-16 用户定：字幕默认都是单行，
// 除非用户在面板上调成两行、或者通过 AI 说要两行）。
//
// 管什么：读参数（只认 1 和 2，别的报错；没给是 nil = 按工程记的）。落到工程的那一下在各自的工具里
//（generate_subtitles 经 `setSubtitleMaxLines`、add_voiceover 在同一次 perform 里写 `subtitleMaxLines`），和面板同一个开关。
// 不管什么：按几行切（SrtFlowCore 的 `SubtitleBreaks`）、什么时候生成。

enum AISubtitleLines {
    static let key = "max_lines"

    /// 没给就是 nil（按工程记的）；给了只认 `SubtitleSegmentationConfig.lineCountRange` 里的数。
    static func parse(_ args: AIToolArguments) throws -> Int? {
        guard let lines = try args.int(key) else { return nil }
        guard SubtitleSegmentationConfig.lineCountRange.contains(lines) else {
            throw AIToolError("\(key) is how many lines one subtitle may take: 1 (default) or 2.")
        }
        return lines
    }
}

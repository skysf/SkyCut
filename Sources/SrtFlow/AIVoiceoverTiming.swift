import Foundation

// MARK: - 配音的字幕时间从哪来（纯值）
//
// 管什么（SkyCut 声音方案第七节，约定第 5 条）：一句配音的字幕时间是怎么得来的，结果和 get_job 里报成 `subtitle_timing`：
// - `provider`：读的那一方报了每个字什么时候说（Eleven v4 的字符时间、本机 Kokoro / macOS 声音的词标记）；
// - `aligned`：这台 Mac 把成品转写一遍，再按原文对齐（SpeechWordAlignment）；
// - `estimated`：按字数估（SpeechWordEstimate：本机转写不了、或这一句转写和原文对不上），可能差半秒左右，AI 要转告用户。
// 整段的报法：每句一样就是那一种，不一样是 `mixed`（`summary`）。
// 不管什么：怎么对齐、怎么估（各自的类型）；什么时候用哪一种（SkyStudioVoiceReading、SkyStudioVoiceRender）。

enum AIVoiceoverTiming: String, Codable, Sendable, CaseIterable {
    case provider, aligned, estimated

    /// 几句不是同一种时整段报的值。
    static let mixed = "mixed"

    /// 整段的 `subtitle_timing`：每句一样就是那一种，不一样是 mixed；一句都没有（没有字幕）是 nil。
    static func summary(_ lines: [AIVoiceoverTiming]) -> String? {
        guard let first = lines.first else { return nil }
        return lines.allSatisfy { $0 == first } ? first.rawValue : mixed
    }

    /// 同一句的几片来自不同的批（长句跨批）时，这一句算哪一种：取最不可靠的那个（估 < 对齐 < 报的）。
    static func weakest(_ sources: [AIVoiceoverTiming]) -> AIVoiceoverTiming? {
        sources.max { $0.rank < $1.rank }
    }

    private var rank: Int {
        switch self {
        case .provider: return 0
        case .aligned: return 1
        case .estimated: return 2
        }
    }

    /// 估出来的那几句要转告用户的话（结果的 voice.note）。`lines` 是这次有字幕的句数。
    static func estimatedNote(estimated: Int, of lines: Int) -> String {
        let which = estimated == lines ? "all lines" : "\(estimated) of \(lines) lines (subtitles.estimated_line_indices, zero-based)"
        return "Subtitle timing for \(which) is estimated from character counts and may be off by about half a second. Tell the user."
    }
}

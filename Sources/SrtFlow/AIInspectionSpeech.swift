import Foundation
import SrtFlowCore

// MARK: - 成片检查判「切在说话上」：只拿人声判（纯值）
//
// 管什么：inspect_video 查素材切口时，一刀落在有声的地方（电平上附近没有停顿，`AICutCheck.side` 判的），算不算「切在说话上」
// （`audio_cutoff`）：
// - **素材自己的头尾什么都没切掉**：入点在文件开头、出点在文件结尾的那一头不查。合成音效、旁白文件、从头放的音乐都从第 0 秒开始，
//   以前它们的起点全被报成切在说话上。
// - **只拿人声的证据判**：这一段转写缓存里的词（识别器原样的源秒）；没有转写时用原文字幕里记着出处的句子（配音、生成字幕都记
//   `CueMeta.provenance`：从哪一段来、素材里的哪几秒），只在那一段用到的源秒范围里算数（范围外没人听过）。落在一个词 / 一句
//   里面才报；有证据但这一刻没在说话（音乐、音效、环境声、底噪）不报。
// - 两样都没有：判不了，不当成切在说话上，由调用方列进 `speech_unchecked`（叫 AI 先 transcribe 有人声的那几段）。
// 由来：MCP-14，两条 AI 剪的南极预告片里音效、音乐、环境声的起点被报成「切在说话上」，真问题淹在里面
// （docs/bugfixes/2026-11-16-inspection-reports-sound-onsets-as-speech.md）。合同见 docs/architecture/finished-video-inspection.md。
// Since 2026-11-19 listen cuts=true judges its V1 cuts with the same evidence (`AICutCheck.speechJudged`): one rule, two tools.
// 不管什么：电平上在不在停顿里（`AICutCheck.side`，和 listen cuts=true 同一份）；转写缓存怎么读（`AISpeechCutTool.transcript`）。

enum AIInspectionSpeech {
    enum Voice: Equatable {
        /// 切在说话上：切到的词（转写）或那一句的开头几个字（字幕）。
        case on(String)
        /// 有人声的证据，但这一刻没在说话。
        case off
        /// 没有人声的证据：判不了。
        case unknown
    }

    /// 一句说话在素材里的几秒（源秒）和它的字。
    struct Line: Equatable {
        var span: ClosedRange<Double>
        var text: String
    }

    /// 一个素材文件里字幕记着的说话：哪几句、这些字幕是从文件的哪几截听出来的（出处那几段的源秒范围）。
    struct Subtitled: Equatable {
        var lines: [Line] = []
        var heard: [ClosedRange<Double>] = []
    }

    /// 这一头切的是不是素材自己的头 / 尾：入点在文件开头（`start`）、出点在文件结尾 —— 什么都没切掉。
    /// 文件多长不知道（没探到时长）时，出点那一头不算。
    static func isFileEdge(_ clip: EditClip, start: Bool, tolerance: Double) -> Bool {
        isFileEdge(clip, atSource: start ? clip.sourceStart : clip.sourceStart + clip.sourceDuration, start: start, tolerance: tolerance)
    }

    /// The same at a source second of `sound`'s file: listen cuts=true asks it on the sound a V1 cut is heard from, which may be
    /// a linked clip whose own edges sit elsewhere.
    static func isFileEdge(_ sound: EditClip, atSource time: Double, start: Bool, tolerance: Double) -> Bool {
        if start { return time <= tolerance }
        guard let length = sound.info?.duration ?? sound.audioAssetDuration, length > 0 else { return false }
        return time >= length - tolerance
    }

    /// 原文字幕里记着出处的句子，按素材文件归（分割出来的右半段 id 不一样，文件和源秒是同一份）。出处那一段已经不在时间线上的不算。
    static func subtitled(in state: TimelineState) -> [URL: Subtitled] {
        guard let meta = state.subtitleCompanion?.cueMeta, !meta.isEmpty else { return [:] }
        var result: [URL: Subtitled] = [:]
        for cue in state.subtitleCues(of: .original) {
            guard let provenance = meta[cue.id]?.provenance, let id = provenance.clipID,
                  let from = provenance.sourceStart, let to = provenance.sourceEnd, to > from,
                  let host = state.clip(with: id) else { continue }
            var entry = result[host.sourceURL] ?? Subtitled()
            entry.lines.append(Line(span: from...to, text: cue.text))
            let window = host.sourceStart...(host.sourceStart + host.sourceDuration)
            if !entry.heard.contains(window) { entry.heard.append(window) }
            result[host.sourceURL] = entry
        }
        return result
    }

    /// 源秒 `time` 上是不是在说话。`words`：这一段转写缓存里的词（nil = 没转写过）；`subtitles`：这个文件字幕记着的说话。
    /// 有转写就只看词（比字幕的一句细）；没有才看字幕，而且只在字幕听过的那几截里算数。
    static func voice(atSource time: Double, words: [TimedWord]?, subtitles: Subtitled?) -> Voice {
        if let words {
            guard let word = words.first(where: { $0.start <= time && time <= $0.end }) else { return .off }
            return .on(word.text)
        }
        guard let subtitles, subtitles.heard.contains(where: { $0.contains(time) }) else { return .unknown }
        guard let line = subtitles.lines.first(where: { $0.span.contains(time) }) else { return .off }
        return .on(String(line.text.prefix(24)))
    }
}

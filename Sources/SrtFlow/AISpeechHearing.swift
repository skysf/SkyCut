import Foundation
import SrtFlowCore

// MARK: - 判切口要听的那一份：整个素材文件的电平、门限和词（纯值）
//
// 管什么：cut_speech 和 listen cuts=true 判一刀在不在停顿里用的是同一个判法（`AISpeechCutPoints`），这里给它**同一份输入**：
// - 电平窗：整个素材文件的（`AIAudioLevels.windows`，画波形那一份数据），源秒；
// - 门限：AI 给了 silence_db 就用它；没给就是**按整个文件量的**（`AISpeechCuts.silenceThreshold`）和 listen 的默认值里宽的那个 ——
//   不随片段剪成多长变；
// - 词：整个文件转写缓存里的词，按 transcribe 那一套估过开口（`SpeechTranscript`），源秒；没转写过是空的。
// 以前两边各量各的：cut_speech 量调用时那段片段、用片段里的词，剪辑点检查量剪完那一小段前后各 1 秒、用识别器原样的词 ——
// 同一个源时刻门限差 1 dB、停顿起点差 46 ms、切到的词一个是「available.」一个是「The」（2026-10-18 L16，
// docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。
// 不管什么：判法（AISpeechCutPoints）；波形和转写缓存怎么读（AISpeechCutTool 的 `wholeFile` / `transcript`）；
// 删停顿（remove_pauses）照旧量调用时那段片段（AISpeechCutTool）。

struct AISpeechHearing {
    /// 整个文件的电平窗（源秒）；读不出声音是 nil。
    let levels: [AIAudioLevels.Window]?
    /// 整个文件的词（源秒，估过开口，同 transcribe 读出来的）；没转写过是空的。
    let words: [SpeechTranscript.Word]
    /// 转写缓存里有没有这个文件（没有时只按声音判，结果里要说一句）。
    let hasTranscript: Bool
    /// 按整个文件量的门限（dB）；读不出声音是 nil。
    let measuredDB: Double?

    /// - Parameters:
    ///   - levels: 整个文件的电平窗（源秒）；读不出声音传 nil。
    ///   - transcript: 转写缓存里这个文件的词（识别器原样的源秒）；没转写过传 nil。
    init(levels: [AIAudioLevels.Window]?, transcript: [TimedWord]?) {
        self.levels = levels
        measuredDB = levels.map { AISpeechCuts.silenceThreshold($0.map(\.decibels)) }
        hasTranscript = transcript != nil
        // 整个文件当一个窗口：词按说话中点归窗口、开口照 transcribe 估（SubtitleSegmenter.placed），时间线秒就是源秒。
        let whole = SubtitleClipWindow(clipID: UUID(), assetFingerprint: "", sourceStart: 0, sourceEnd: .infinity, timelineStart: 0)
        words = transcript.map { SpeechTranscript.sentences(words: $0, window: whole).flatMap(\.words) } ?? []
    }

    /// 判切口的静音门限：AI 给了就用它；没给就是整个文件量的和 listen 的默认值里宽的那个（AI 照 listen 报的静音挑的一刻，
    /// 这里也要算在停顿里）。
    func silenceDB(_ asked: Double?) -> Double {
        asked ?? max(measuredDB ?? AIAudioLevels.defaultSilenceDB, AIAudioLevels.defaultSilenceDB)
    }

    /// 判点：`clip` 给了就按它在时间线上的秒问（cut_speech）；nil = 问源秒（listen cuts=true）。
    func points(silenceDB asked: Double?, snaps: Bool = true, clip: EditClip? = nil) -> AISpeechCutPoints {
        AISpeechCutPoints(words: words, levels: levels, silenceDB: silenceDB(asked), snaps: snaps, clip: clip)
    }
}

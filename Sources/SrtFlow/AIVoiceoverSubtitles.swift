import Foundation
import SrtFlowCore

// MARK: - 配音的字幕（纯值）
//
// 管什么：add_voiceover 的 subtitles=true —— 配音的每个词在哪一刻是知道的（AIVoiceWords），直接切成字幕：断句、去标点、
// 一行多长、显示时间全走生成字幕那一套（`SubtitleSegmenter.segment` + `assemble`，docs/architecture/subtitle-generation-style.md），
// 不另写一份。然后加进原文字幕轨：
// - **不覆盖用户的字幕**：和已有的句子在时间上重叠的那几句不加，结果里报几句没加。
// - **一个语言一条轨**：原文轨已经是别的语言（记的语言；没记就按字判断，字太少不判）就一句都不加，说清楚。
// - 还没有字幕轨就建一条，语言记成配音的语言。
// - 每句记下是哪段配音生成的（`CueMeta.provenance`）：挪配音段时字幕跟着走（`CaptionSourceFollow`）。
// 不管什么：配音怎么合成、放上时间线（AIVoiceoverTool）。

enum AIVoiceoverSubtitles {
    /// 一段配音在时间线上的样子 + 它的词（文件里的秒）。
    struct Piece {
        var clipID: UUID
        var timelineStart: Double
        var duration: Double
        var laneRank: Int
        var words: [TimedWord]
    }

    struct Outcome: Equatable {
        var added: [UUID] = []
        /// 和已有字幕重叠、没加的句数。
        var skipped = 0
        /// 一句都没加的原因（语言对不上）。
        var refusal: String?
    }

    /// 配音字幕的分段参数：生成字幕那一套（每行多长、显示多久），只是**不按逗号拆**（`splitsAtClauses`）—— 一句旁白是写稿时定好的
    /// 一条，整句放得下就一条，放不下才切（照样优先切在逗号后面）。2026-10-06 盲测：「在地球的最南端，冰统治着一切」切成两条
    /// 一秒出头的半句（docs/bugfixes/2026-10-14-voiceover-subtitles-split-at-commas.md）。
    static func config(languageCode: String, frameDuration: Double, maxLineEms: Double) -> SubtitleSegmentationConfig {
        var config = SubtitleSegmentationConfig.generation(
            languageCode: languageCode, frameDuration: frameDuration, maxLineEms: maxLineEms
        )
        config.splitsAtClauses = false
        return config
    }

    /// `language` 是配音的语言（zh、en…，BCP-47 的第一段）。
    static func add(
        _ pieces: [Piece], language: String, config: SubtitleSegmentationConfig, to state: inout TimelineState
    ) -> Outcome {
        let existing = state.subtitleCues(of: .original)
        if !existing.isEmpty,
           let trackLanguage = state.subtitleCompanion?.sourceLanguage ?? detectedLanguage(of: existing),
           AIVoiceChoice.baseLanguage(trackLanguage) != language {
            return Outcome(refusal: "The subtitle track is in \(trackLanguage) and the voiceover is in \(language); "
                + "a project has one subtitle track per language, so no subtitles were added.")
        }
        let windows = pieces.map { piece in
            SubtitleClipWindow(
                clipID: piece.clipID, assetFingerprint: "voiceover-\(piece.clipID.uuidString)",
                sourceStart: 0, sourceEnd: piece.duration, timelineStart: piece.timelineStart, speed: 1, laneRank: piece.laneRank
            )
        }
        let parts = zip(pieces, windows).map { piece, window in
            SubtitleSegmenter.segment(words: piece.words, window: window, config: config)
        }
        let assembled = SubtitleSegmenter.assemble(parts, windows: windows, config: config)
        let cues = assembled.document.cues
        // 一句都切不出来（全是标点）就别建一条空的字幕轨。
        guard !cues.isEmpty else { return Outcome() }
        var outcome = Outcome()
        state.editSubtitleTracks(creatingOriginal: true) { original, companion in
            for cue in cues {
                // 贴着的不算重叠（半帧以内）。
                let overlaps = original.cues.contains { $0.start < cue.end - 0.02 && cue.start < $0.end - 0.02 }
                if overlaps {
                    outcome.skipped += 1
                    continue
                }
                // 整句抄过来、只换身份：词的时间（逐词高亮）跟着走，别手写逐字段构造（漏字段）。
                var fresh = cue
                fresh.id = UUID()
                if let id = SubtitleTrackEditing.insertCue(fresh, into: .original, original: &original, companion: &companion) {
                    outcome.added.append(id)
                    // 记下是哪段配音生成的（`insertCue` 记成人工、没有来源）：挪配音段时字幕跟着走（`CaptionSourceFollow`，
                    // docs/bugfixes/2026-10-14-voiceover-subtitles-stay-behind.md）。
                    companion.cueMeta[id] = CueMeta(origin: .generated, provenance: assembled.meta[cue.id]?.provenance)
                }
            }
            if companion.sourceLanguage == nil, !outcome.added.isEmpty { companion.sourceLanguage = language }
        }
        return outcome
    }

    /// 轨上没记语言时按字判断；字太少（一两个词）判不准，不判 —— 宁可加上，也不因为「Mine」像德语就一句不加。
    static let minimumCharactersToDetect = 20

    private static func detectedLanguage(of cues: [SubtitleCue]) -> String? {
        let texts = cues.map(\.text)
        guard texts.joined().count >= minimumCharactersToDetect else { return nil }
        return AITextLanguage.dominant(in: texts)
    }
}

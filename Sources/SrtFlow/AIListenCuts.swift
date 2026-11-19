import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen cuts=true：把 V1 的每个剪辑点一次查完（读波形、读转写缓存；判法在 AICutCheck / AISpeechCutPoints）
//
// 管什么：V1 每一段的头和尾（`AICutCheck.boundaries`），每一头去听它的声音 —— 声音从哪段来同 cut_speech（自己有声就是自己、
// 静音了 / 声音分离出去了就是链接的那段，`AISpeechCutTool.speechClip`）。判的输入和 cut_speech **同一份**（`AISpeechHearing`）：
// 整个素材文件的波形（`AISpeechCutTool.wholeFile`，画时间线那一份，一次最多等 40 秒，没读完的那几头报「还在读」）、
// 按整个文件量的门限（AI 给了 silence_db 就用它）、整个文件的词（`AISpeechCutTool.transcript`：**转写只读缓存**，不起任务 ——
// listen 是只读工具；没有就只按声音判并说一句）。所以这里说「在停顿里 / 最安静的一格 / 在声音上、挪到哪」，cut_speech 在同一个
// 源时刻也是这么判、挪到同一个地方（2026-10-18：以前量剪完那一小段前后各 1 秒、用识别器原样的词，和 cut_speech 判得不一样，
// docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。一个素材文件只听一遍，几段、几个剪辑点共用。
// Since 2026-11-19 (MCP-14) a side the levels put on speech is judged on speech evidence the way inspect_video does
// (`AICutCheck.speechJudged`, AIInspectionSpeech): each sound clip's cached words and the narration subtitles; without either it
// is on_sound and its clip is listed in speech_unchecked, never a cut on speech (docs/bugfixes/2026-11-19-listen-cuts-reports-sound-onsets-as-speech.md).
// 不管什么：判法（AICutCheck、AISpeechCutPoints）、说明文字（SrtFlowMCPKit/MCPSenseTools.swift）。

@MainActor
enum AIListenCuts {
    /// 一次最多报多少个剪辑点。
    static let maxBoundaries = 80

    static func check(
        _ state: TimelineState, _ ids: AIShortIDs, from: Double?, to: Double?, silenceDB: Double?, deadline: Date
    ) async throws -> JSONValue {
        guard !state.mainClips.isEmpty else { throw AIToolError("Nothing on V1 to check: cuts=true looks at the V1 clips.") }
        let boundaries = AICutCheck.boundaries(of: state.mainClips, from: from, to: to)
        guard !boundaries.isEmpty else { throw AIToolError("No V1 cut between from and to.") }
        let shown = Array(boundaries.prefix(maxBoundaries))

        // 每个素材文件听一遍（几段、几个剪辑点共用）；每段声音的转写缓存各读一次（缓存按片段认，判切在不在词上用它自己的词）。
        var sounds: [UUID: EditClip] = [:]
        var heard: [URL: Heard] = [:]
        var words: [UUID: [TimedWord]?] = [:]
        for clip in shown.flatMap({ [$0.outgoing, $0.incoming].compactMap { $0 } }) where sounds[clip.id] == nil {
            let sound = AISpeechCutTool.speechClip(of: clip, in: state)
            sounds[clip.id] = sound
            guard audible(sound) == nil else { continue }
            if words[sound.id] == nil { words[sound.id] = .some(await AISpeechCutTool.transcript(of: sound, in: state, language: "auto")?.words) }
            if heard[sound.sourceURL] == nil {
                heard[sound.sourceURL] = await hear(sound, words: words[sound.id] ?? nil, silenceDB: silenceDB, deadline: deadline)
            }
        }

        let frame = state.frameRate.secondsPerFrame
        let evidence = Evidence(words: words, subtitles: AIInspectionSpeech.subtitled(in: state), tolerance: frame)
        var unchecked: Set<UUID> = []
        var edges: [AICutCheck.Edge] = []
        for boundary in shown {
            var edge = AICutCheck.Edge(at: boundary.at, transition: boundary.transition)
            if let clip = boundary.outgoing {
                edge.outgoing = side(of: clip, end: .end, at: clip.timelineEnd, state, sounds, heard, frame, evidence, &unchecked)
            }
            if let clip = boundary.incoming {
                edge.incoming = side(of: clip, end: .start, at: clip.timelineStart, state, sounds, heard, frame, evidence, &unchecked)
            }
            edges.append(edge)
        }

        var result: [String: JSONValue] = [
            "cuts": .array(AICutCheck.json(edges, ids: ids)),
            "checked": .number(Double(edges.count)),
            "on_speech": .number(Double(AICutCheck.onSpeechCount(edges))),
            "on_sound": .number(Double(AICutCheck.onSoundCount(edges)))
        ]
        if !unchecked.isEmpty {
            result["speech_unchecked"] = [
                "clips": .array(unchecked.map { ids.short($0) }.sorted().map { .string($0) }),
                "why": "These clips are cut where sound plays, but they have no transcript or narration subtitles, so SkyCut can't tell speech from music, effects or ambience there. Call transcribe on the ones with speech, then check again."
            ]
        }
        if boundaries.count > shown.count { result["more_cuts"] = .number(Double(boundaries.count - shown.count)) }
        result["silence_db"] = silenceDB.map { JSONValue.number($0) } ?? .string("measured over each media file (at least -45)")
        let transcripts = heard.values.compactMap { listened -> Bool? in
            if case .points(_, let transcript) = listened { return transcript }
            return nil
        }
        let withTranscript = transcripts.filter { $0 }.count
        if withTranscript == 0 {
            result["transcript"] = "none: a cut where sound plays is on_sound, not on_speech; call transcribe on the V1 clips with speech to see which word a cut lands on"
        } else if withTranscript < transcripts.count {
            result["transcript"] = .string(
                "\(withTranscript) of \(transcripts.count) media files with sound have a transcript; cuts on the others' sound are on_sound unless narration subtitles show a line"
            )
        }
        result["note"] = .string(
            "in_pause: the cut sits in a pause of that clip's sound. quiet_spot: no full pause nearby, so it sits in the quietest "
                + "moment between two words (fine as it is). on_speech: it cuts into speech (a transcript word or a narration line is "
                + "there); suggested_source_in / suggested_source_out is the nearest pause, in that clip's source seconds: pass it to "
                + "edit_clip (a trim keeps the clip's timeline start; add ripple=true so the later V1 clips follow a changed end). "
                + "on_sound: sound plays but no word is there (music, an effect, ambience), or nothing says (speech_unchecked). "
                + "file_edge: the file's own first or last second, nothing is cut. Speech is judged as inspect_video judges it; cut_speech "
                + "judges and moves cuts on speech the same way."
        )
        return .object(result)
    }

    // MARK: 一个素材文件

    /// 听过的一个素材文件：在它源时间轴上建的判点、有没有转写；量不了时是为什么。
    private enum Heard {
        case points(AISpeechCutPoints, transcript: Bool)
        case unheard(String)
    }

    /// The speech evidence a side on speech is judged with (AIInspectionSpeech): each sound clip's cached words (nil = never
    /// transcribed) and the narration subtitles by file; a frame of slack at a file's own edges.
    private struct Evidence {
        let words: [UUID: [TimedWord]?]
        let subtitles: [URL: AIInspectionSpeech.Subtitled]
        let tolerance: Double
    }

    /// 这段声音量不了的原因（没有声音 / 静音了）；能听是 nil。
    private static func audible(_ sound: EditClip) -> String? {
        guard sound.hasAudio else { return "no sound: this clip has no audio" }
        guard !sound.isMuted, sound.volume > 0 else { return "muted: nothing to hear at this cut" }
        return nil
    }

    /// 整个文件听一遍：波形和转写缓存建成源秒上的判点（AISpeechHearing，和 cut_speech 同一份）。`words`：这段声音的转写缓存。
    private static func hear(_ sound: EditClip, words: [TimedWord]?, silenceDB: Double?, deadline: Date) async -> Heard {
        switch await AISpeechCutTool.wholeFile(of: sound, until: deadline) {
        case .unreadable:
            return .unheard("unreadable: SkyCut could not read this clip's audio")
        case .reading:
            return .unheard("still reading: SkyCut is reading this file's audio, call listen again in a moment")
        case .ready(let peaks):
            let levels = AIAudioLevels.windows(peaks, from: 0, to: peaks.duration)
            guard !levels.isEmpty else { return .unheard("unreadable: no audio in this clip's file") }
            let hearing = AISpeechHearing(levels: levels, transcript: words)
            return .points(hearing.points(silenceDB: silenceDB), transcript: hearing.hasTranscript)
        }
    }

    // MARK: 一头

    private static func side(
        of clip: EditClip, end: AISpeechCutPoints.Side, at: Double,
        _ state: TimelineState, _ sounds: [UUID: EditClip], _ heard: [URL: Heard], _ frame: Double,
        _ evidence: Evidence, _ unchecked: inout Set<UUID>
    ) -> AICutCheck.Side {
        if clip.isHidden || state.mainHidden { return AICutCheck.unheard(clip, end: end, at: at, "hidden: not in the video") }
        guard let sound = sounds[clip.id] else { return AICutCheck.unheard(clip, end: end, at: at, "not measured") }
        if let reason = audible(sound) { return AICutCheck.unheard(clip, end: end, at: at, reason) }
        switch heard[sound.sourceURL] {
        case .unheard(let reason)?: return AICutCheck.unheard(clip, end: end, at: at, reason)
        case .points(let points, _)?:
            let judged = AICutCheck.speechJudged(AICutCheck.side(of: clip, end: end, at: at, sound: sound, points: points, frame: frame),
                                                 sound: sound, words: evidence.words[sound.id] ?? nil,
                                                 subtitles: evidence.subtitles[sound.sourceURL], tolerance: evidence.tolerance)
            if judged.unchecked { unchecked.insert(clip.id) }
            return judged.side
        case nil: return AICutCheck.unheard(clip, end: end, at: at, "not measured")
        }
    }
}

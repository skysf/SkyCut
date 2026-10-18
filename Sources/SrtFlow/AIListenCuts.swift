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

        // 每个素材文件听一遍（几段、几个剪辑点共用）。
        var sounds: [UUID: EditClip] = [:]
        var heard: [URL: Heard] = [:]
        for clip in shown.flatMap({ [$0.outgoing, $0.incoming].compactMap { $0 } }) where sounds[clip.id] == nil {
            let sound = AISpeechCutTool.speechClip(of: clip, in: state)
            sounds[clip.id] = sound
            if audible(sound) == nil, heard[sound.sourceURL] == nil {
                heard[sound.sourceURL] = await hear(sound, state: state, silenceDB: silenceDB, deadline: deadline)
            }
        }

        let frame = state.frameRate.secondsPerFrame
        var edges: [AICutCheck.Edge] = []
        for boundary in shown {
            var edge = AICutCheck.Edge(at: boundary.at, transition: boundary.transition)
            if let clip = boundary.outgoing { edge.outgoing = side(of: clip, end: .end, at: clip.timelineEnd, state, sounds, heard, frame) }
            if let clip = boundary.incoming { edge.incoming = side(of: clip, end: .start, at: clip.timelineStart, state, sounds, heard, frame) }
            edges.append(edge)
        }

        var result: [String: JSONValue] = [
            "cuts": .array(AICutCheck.json(edges, ids: ids)),
            "checked": .number(Double(edges.count)),
            "on_speech": .number(Double(AICutCheck.onSpeechCount(edges)))
        ]
        if boundaries.count > shown.count { result["more_cuts"] = .number(Double(boundaries.count - shown.count)) }
        result["silence_db"] = silenceDB.map { JSONValue.number($0) } ?? .string("measured over each media file (at least -45)")
        let transcripts = heard.values.compactMap { listened -> Bool? in
            if case .points(_, let transcript) = listened { return transcript }
            return nil
        }
        let withTranscript = transcripts.filter { $0 }.count
        if withTranscript == 0 {
            result["transcript"] = "none: judged by sound alone; call transcribe on the V1 clips to see which word a cut lands on"
        } else if withTranscript < transcripts.count {
            result["transcript"] = .string(
                "\(withTranscript) of \(transcripts.count) media files with sound have a transcript; the others are judged by sound alone"
            )
        }
        result["note"] = .string(
            "in_pause: the cut sits in a pause of that clip's sound. quiet_spot: no full pause nearby, so it sits in the quietest "
                + "moment between two words (fine as it is). on_speech: it cuts into speech; suggested_source_in / "
                + "suggested_source_out is the nearest pause, in that clip's source seconds: pass it to edit_clip (a trim keeps the clip's "
                + "timeline start; add ripple=true so the later V1 clips follow a changed end). cut_speech judges and moves cuts the same way."
        )
        return .object(result)
    }

    // MARK: 一个素材文件

    /// 听过的一个素材文件：在它源时间轴上建的判点、有没有转写；量不了时是为什么。
    private enum Heard {
        case points(AISpeechCutPoints, transcript: Bool)
        case unheard(String)
    }

    /// 这段声音量不了的原因（没有声音 / 静音了）；能听是 nil。
    private static func audible(_ sound: EditClip) -> String? {
        guard sound.hasAudio else { return "no sound: this clip has no audio" }
        guard !sound.isMuted, sound.volume > 0 else { return "muted: nothing to hear at this cut" }
        return nil
    }

    /// 整个文件听一遍：波形和转写缓存建成源秒上的判点（AISpeechHearing，和 cut_speech 同一份）。
    private static func hear(_ sound: EditClip, state: TimelineState, silenceDB: Double?, deadline: Date) async -> Heard {
        switch await AISpeechCutTool.wholeFile(of: sound, until: deadline) {
        case .unreadable:
            return .unheard("unreadable: SrtFlow could not read this clip's audio")
        case .reading:
            return .unheard("still reading: SrtFlow is reading this file's audio, call listen again in a moment")
        case .ready(let peaks):
            let levels = AIAudioLevels.windows(peaks, from: 0, to: peaks.duration)
            guard !levels.isEmpty else { return .unheard("unreadable: no audio in this clip's file") }
            let transcript = await AISpeechCutTool.transcript(of: sound, in: state, language: "auto")
            let hearing = AISpeechHearing(levels: levels, transcript: transcript?.words)
            return .points(hearing.points(silenceDB: silenceDB), transcript: hearing.hasTranscript)
        }
    }

    // MARK: 一头

    private static func side(
        of clip: EditClip, end: AISpeechCutPoints.Side, at: Double,
        _ state: TimelineState, _ sounds: [UUID: EditClip], _ heard: [URL: Heard], _ frame: Double
    ) -> AICutCheck.Side {
        if clip.isHidden || state.mainHidden { return AICutCheck.unheard(clip, end: end, at: at, "hidden: not in the video") }
        guard let sound = sounds[clip.id] else { return AICutCheck.unheard(clip, end: end, at: at, "not measured") }
        if let reason = audible(sound) { return AICutCheck.unheard(clip, end: end, at: at, reason) }
        switch heard[sound.sourceURL] {
        case .unheard(let reason)?: return AICutCheck.unheard(clip, end: end, at: at, reason)
        case .points(let points, _)?: return AICutCheck.side(of: clip, end: end, at: at, sound: sound, points: points, frame: frame)
        case nil: return AICutCheck.unheard(clip, end: end, at: at, "not measured")
        }
    }
}

import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen cuts=true：把 V1 的每个剪辑点一次查完（读波形、读转写缓存；判法在 AICutCheck / AISpeechCutPoints）
//
// 管什么：V1 每一段的头和尾（`AICutCheck.boundaries`），每一头去听它的声音 —— 声音从哪段来同 cut_speech（自己有声就是自己、
// 静音了 / 声音分离出去了就是链接的那段，`AISpeechCutTool.speechClip`）；波形是画时间线那一份（`AIListenTool.waveform`，
// 一次最多等 40 秒，没读完的那几头报「还在读」）；**转写只读缓存**（`AITranscribeTool.cached`，不起任务：listen 是只读工具），
// 没有就只按声音判并说一句；门限同 cut_speech（AI 给的 silence_db，没给就是这一段自己量的和 listen 默认值里宽的那个）。
// 一段声音几个剪辑点共用（只听一遍），切口前后各多听 `margin` 秒：切掉的那半个词、下一句的开口都在这一截里。
// 不管什么：判法（AICutCheck、AISpeechCutPoints）、说明文字（SrtFlowMCPKit/MCPSenseTools.swift）。

@MainActor
enum AIListenCuts {
    /// 一次最多报多少个剪辑点。
    static let maxBoundaries = 80
    /// 切口前后各多听多远（源秒）。
    static let margin = 1.0

    static func check(
        _ state: TimelineState, _ ids: AIShortIDs, from: Double?, to: Double?, silenceDB: Double?, deadline: Date
    ) async throws -> JSONValue {
        guard !state.mainClips.isEmpty else { throw AIToolError("Nothing on V1 to check: cuts=true looks at the V1 clips.") }
        let boundaries = AICutCheck.boundaries(of: state.mainClips, from: from, to: to)
        guard !boundaries.isEmpty else { throw AIToolError("No V1 cut between from and to.") }
        let shown = Array(boundaries.prefix(maxBoundaries))

        // 每段声音听一遍（几个剪辑点共用）。
        var sounds: [UUID: EditClip] = [:]
        var heard: [UUID: Listened] = [:]
        for clip in shown.flatMap({ [$0.outgoing, $0.incoming].compactMap { $0 } }) where sounds[clip.id] == nil {
            let sound = AISpeechCutTool.speechClip(of: clip, in: state)
            sounds[clip.id] = sound
            if heard[sound.id] == nil { heard[sound.id] = await listen(sound, state: state, silenceDB: silenceDB, deadline: deadline) }
        }

        var edges: [AICutCheck.Edge] = []
        for boundary in shown {
            var edge = AICutCheck.Edge(at: boundary.at, transition: boundary.transition)
            if let clip = boundary.outgoing { edge.outgoing = side(of: clip, end: .end, at: clip.timelineEnd, state, sounds, heard) }
            if let clip = boundary.incoming { edge.incoming = side(of: clip, end: .start, at: clip.timelineStart, state, sounds, heard) }
            edges.append(edge)
        }

        var result: [String: JSONValue] = [
            "cuts": .array(AICutCheck.json(edges, ids: ids)),
            "checked": .number(Double(edges.count)),
            "on_speech": .number(Double(AICutCheck.onSpeechCount(edges)))
        ]
        if boundaries.count > shown.count { result["more_cuts"] = .number(Double(boundaries.count - shown.count)) }
        result["silence_db"] = silenceDB.map { JSONValue.number($0) } ?? .string("measured per clip (at least -45)")
        let transcripts = heard.values.compactMap { listened -> Bool? in
            if case .points(_, let transcript) = listened { return transcript }
            return nil
        }
        let withTranscript = transcripts.filter { $0 }.count
        if withTranscript == 0 {
            result["transcript"] = "none: judged by sound alone; call transcribe on the V1 clips to see which word a cut lands on"
        } else if withTranscript < transcripts.count {
            result["transcript"] = .string(
                "\(withTranscript) of \(transcripts.count) clips with sound have a transcript; the others are judged by sound alone"
            )
        }
        result["note"] = .string(
            "in_pause: the cut sits in a pause of that clip's sound. quiet_spot: no full pause nearby, so it sits in the quietest "
                + "moment between two words (fine as it is). on_speech: it cuts into speech; suggested_source_in / "
                + "suggested_source_out is the nearest pause, in that clip's source seconds: pass it to edit_clip (a trim keeps the clip's "
                + "timeline start; add ripple=true so the later V1 clips follow a changed end)."
        )
        return .object(result)
    }

    // MARK: 一段声音

    /// 听过的一段声音：在它源时间轴上建的判点、有没有转写；量不了时是为什么。
    private enum Listened {
        case points(AISpeechCutPoints, transcript: Bool)
        case unheard(String)
    }

    private static func listen(_ sound: EditClip, state: TimelineState, silenceDB: Double?, deadline: Date) async -> Listened {
        guard sound.hasAudio else { return .unheard("no sound: this clip has no audio") }
        guard !sound.isMuted, sound.volume > 0 else { return .unheard("muted: nothing to hear at this cut") }
        guard let peaks = await AIListenTool.waveform(of: sound.sourceURL, until: deadline) else {
            return .unheard("unreadable: SrtFlow could not read this clip's audio")
        }
        let from = max(0, sound.sourceStart - margin)
        let to = min(sound.sourceStart + sound.sourceDuration + margin, sound.assetDuration)
        guard peaks.isComplete || peaks.duration >= to - 0.01 else {
            return .unheard("still reading: SrtFlow is reading this file's audio, call listen again in a moment")
        }
        let levels = AIAudioLevels.windows(peaks, from: from, to: to)
        guard !levels.isEmpty else { return .unheard("unreadable: no audio around this cut") }
        let threshold = silenceDB ?? max(AISpeechCuts.silenceThreshold(levels.map(\.decibels)), AIAudioLevels.defaultSilenceDB)
        let words = await transcriptWords(of: sound, in: state)
        return .points(AISpeechCutPoints(words: words ?? [], levels: levels, silenceDB: threshold), transcript: words != nil)
    }

    /// 这段声音的转写（源秒）：只读缓存，没转过就是 nil。整个文件转过的词都要 —— 切口前面被切掉的那半个词也在里面。
    private static func transcriptWords(of sound: EditClip, in state: TimelineState) async -> [SpeechTranscript.Word]? {
        guard #available(macOS 26.0, *),
              let entry = SubtitleAudibleClips.soundClips(in: state, only: [sound.id]).first,
              let cached = await AITranscribeTool.cached([entry], language: "auto"),
              let words = cached.entries[entry.fingerprint]?.words else { return nil }
        return words.compactMap { word -> SpeechTranscript.Word? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SpeechTranscript.Word(
                text: text, start: word.start, end: word.end, sourceStart: word.start, sourceEnd: word.end, confidence: word.confidence
            )
        }.sorted { $0.start < $1.start }
    }

    // MARK: 一头

    private static func side(
        of clip: EditClip, end: AISpeechCutPoints.Side, at: Double,
        _ state: TimelineState, _ sounds: [UUID: EditClip], _ heard: [UUID: Listened]
    ) -> AICutCheck.Side {
        if clip.isHidden || state.mainHidden { return AICutCheck.unheard(clip, end: end, at: at, "hidden: not in the video") }
        guard let sound = sounds[clip.id], let listened = heard[sound.id] else {
            return AICutCheck.unheard(clip, end: end, at: at, "not measured")
        }
        switch listened {
        case .unheard(let reason): return AICutCheck.unheard(clip, end: end, at: at, reason)
        case .points(let points, _): return AICutCheck.side(of: clip, end: end, at: at, sound: sound, points: points)
        }
    }
}

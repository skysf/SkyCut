import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// MCP-14：inspect_video 只拿人声判「切在说话上」（docs/bugfixes/2026-11-16-inspection-reports-sound-onsets-as-speech.md）。
// 纯值规则（素材自己的头尾、转写的词、字幕记着的句子）各测一遍，再用合成正弦音的工程走真工具：
// 没有人声证据的切口不报、列进 speech_unchecked；字幕记着这一刻在说话的切口照报；素材自己的头尾不报。
@MainActor
enum SpeechRuleChecks {
    static func run(_ project: VideoEditProject, source: URL, info: MediaInfo, require: (Bool, String) -> Void) async throws {
        pureRules(source: source, require: require)
        var state = TimelineState()
        state.frameRate = .fps24
        // 正弦音一直响：第一段的尾（源秒 3）、第二段的头（源秒 4）电平上都「切在有声处」；第一段的头、第二段的尾是文件自己的头尾。
        let first = EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info)
        let second = EditClip(sourceURL: source, sourceStart: 4, sourceDuration: 4, timelineStart: 4, info: info)
        state.mainClips = [first, second]
        let plain = try await inspect(state, project)
        let sourceCuts = findings(plain).filter { ($0["reason"]?.stringValue ?? "").hasPrefix("Source cut on") }
        require(sourceCuts.isEmpty, "a tone with no transcript or narration subtitles is never reported as a cut on speech: \(sourceCuts)")
        let unchecked = Set(plain["speech_unchecked"]?["clips"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let ids = AIShortIDs(state: state)
        require(unchecked == [ids.short(first.id), ids.short(second.id)],
                "clips cut on sound without voice evidence are listed as speech_unchecked: \(unchecked)")

        // 字幕记着第一段源秒 2.5–3.5 在说话、源秒 0–0.5 也在说话：尾（源秒 3）切在说话上，头（文件开头）什么都没切掉。
        var voiced = state
        let spoken = SubtitleCue(id: UUID(), start: 2.5, end: 3, text: "the line goes on")
        let opening = SubtitleCue(id: UUID(), start: 0, end: 0.5, text: "hello")
        voiced.subtitle = SubtitleDocumentModel(cues: [opening, spoken], format: .srt)
        voiced.subtitleCompanion = SubtitleCompanion(origin: .generated, cueMeta: [
            spoken.id: CueMeta(provenance: CueProvenance(clipID: first.id, sourceStart: 2.5, sourceEnd: 3.5)),
            opening.id: CueMeta(provenance: CueProvenance(clipID: first.id, sourceStart: 0, sourceEnd: 0.5))
        ])
        let heard = try await inspect(voiced, project)
        let onSpeech = findings(heard).filter { ($0["reason"]?.stringValue ?? "").hasPrefix("Source cut on speech") }
        require(onSpeech.count == 1 && onSpeech.first?["at"]?.doubleValue.map { abs($0 - 3) < 0.001 } == true
                    && onSpeech.first?["items"]?.arrayValue?.first?.stringValue == ids.short(first.id),
                "a cut inside a line the narration subtitles say is spoken is reported once, at that cut: \(onSpeech)")
        let stillUnchecked = Set(heard["speech_unchecked"]?["clips"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        require(stillUnchecked == [ids.short(second.id)], "only the clip without voice evidence stays unchecked: \(stillUnchecked)")
    }

    private static func pureRules(source: URL, require: (Bool, String) -> Void) {
        let frame = 1.0 / 24
        let sound = EditClip(sourceURL: source, isAudioOnly: true, sourceStart: 4, sourceDuration: 4, audioAssetDuration: 8)
        require(AIInspectionSpeech.isFileEdge(sound, start: false, tolerance: frame), "an out point at the file's end cuts nothing away")
        require(!AIInspectionSpeech.isFileEdge(sound, start: true, tolerance: frame), "an in point inside the file is a real cut")
        var trimmed = sound
        trimmed.sourceStart = 0
        trimmed.sourceDuration = 3
        require(AIInspectionSpeech.isFileEdge(trimmed, start: true, tolerance: frame), "an in point at the file's start cuts nothing away")
        require(!AIInspectionSpeech.isFileEdge(trimmed, start: false, tolerance: frame), "an out point before the file's end is a real cut")
        var unknown = trimmed
        unknown.audioAssetDuration = nil
        unknown.sourceDuration = 8
        require(!AIInspectionSpeech.isFileEdge(unknown, start: false, tolerance: frame), "an unknown file length never counts as the file's end")

        let words = [TimedWord(text: "hello", start: 1, end: 1.4)]
        require(AIInspectionSpeech.voice(atSource: 1.2, words: words, subtitles: nil) == .on("hello"), "a cut inside a transcribed word is on speech")
        require(AIInspectionSpeech.voice(atSource: 1.6, words: words, subtitles: nil) == .off, "a cut between transcribed words is not on speech")
        require(AIInspectionSpeech.voice(atSource: 1.2, words: [], subtitles: nil) == .off, "a transcript without words means no speech")
        let line = AIInspectionSpeech.Line(span: 2.5...3.5, text: "Look at this")
        let heard = AIInspectionSpeech.Subtitled(lines: [line], heard: [0...3])
        require(AIInspectionSpeech.voice(atSource: 3, words: nil, subtitles: heard) == .on("Look at this"), "subtitles mark spoken seconds without a transcript")
        require(AIInspectionSpeech.voice(atSource: 1, words: nil, subtitles: heard) == .off, "outside every spoken line the subtitles heard is not on speech")
        require(AIInspectionSpeech.voice(atSource: 4, words: nil, subtitles: heard) == .unknown, "past the part the subtitles were made from cannot be judged")
        require(AIInspectionSpeech.voice(atSource: 3, words: words, subtitles: heard) == .off, "a transcript is finer than subtitles and wins")
        require(AIInspectionSpeech.voice(atSource: 3, words: nil, subtitles: nil) == .unknown, "no transcript and no narration subtitles cannot be judged")

        var state = TimelineState()
        let host = EditClip(sourceURL: source, sourceStart: 1, sourceDuration: 3, timelineStart: 0)
        state.mainClips = [host]
        let kept = SubtitleCue(id: UUID(), start: 0, end: 1, text: "kept")
        let orphan = SubtitleCue(id: UUID(), start: 1, end: 2, text: "orphan")
        state.subtitle = SubtitleDocumentModel(cues: [kept, orphan], format: .srt)
        state.subtitleCompanion = SubtitleCompanion(cueMeta: [
            kept.id: CueMeta(provenance: CueProvenance(clipID: host.id, sourceStart: 1, sourceEnd: 2)),
            orphan.id: CueMeta(provenance: CueProvenance(clipID: UUID(), sourceStart: 5, sourceEnd: 6))
        ])
        require(AIInspectionSpeech.subtitled(in: state) == [source: .init(lines: [.init(span: 1...2, text: "kept")], heard: [1...4])],
                "subtitle lines come from cues whose source clip is still on the timeline, keyed by its file, heard over that clip's window")
    }

    private static func inspect(_ state: TimelineState, _ project: VideoEditProject) async throws -> JSONValue {
        project.restoreTimeline(state)
        let started = try await AIInspectionTool.start(AIToolArguments(["from": 0, "to": 8, "image": false]), project)
        let job = AIJobs.shared.job(started.payload["job_id"]!.stringValue!)!
        await AIJobs.shared.wait(for: job, seconds: 30)
        return AIJobs.shared.json(job)
    }

    private static func findings(_ result: JSONValue) -> [JSONValue] {
        result["findings"]?.arrayValue ?? []
    }
}

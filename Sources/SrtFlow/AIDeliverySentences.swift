import Foundation
import SrtFlowCore

// Sentence bounds come only from existing transcripts or provenance-bearing narration subtitles.
// Checking these bounds does not start recognition; display subtitle line breaks are not sentences.
@MainActor
enum AIDeliverySentences {
    struct Spoken {
        var clip: EditClip
        var from: Double
        var to: Double
        var text: String
    }

    static func collect(_ state: TimelineState, config: AudioEngineConfig, scope: AIInspection.Scope, unchecked: inout Set<UUID>, token: ExportCancellationToken) async throws -> [Spoken] {
        let ids = Set(config.tracks.filter { $0.fader > 0 && config.master > 0 }.flatMap { $0.segments.map(\.clipID) })
        let subtitles = AIInspectionSpeech.subtitled(in: state)
        let cuts = AIInspectionPicture.visiblePictures(state, from: 0, to: state.duration).flatMap { [$0.timelineStart, $0.timelineEnd] }
        var result: [Spoken] = []
        for clip in state.allClips where ids.contains(clip.id) {
            if token.isCancelled { throw CancellationError() }
            if let transcript = await AISpeechCutTool.transcript(of: clip, in: state, language: "auto") {
                let end = max(clip.assetDuration, transcript.words.map(\.end).max() ?? 0)
                let window = SubtitleClipWindow(clipID: clip.id, assetFingerprint: "inspection", sourceStart: 0, sourceEnd: end,
                                               timelineStart: clip.timelineTime(atSource: 0), speed: clip.speed)
                result += SpeechTranscript.sentences(words: transcript.words, window: window).map {
                    Spoken(clip: clip, from: $0.start, to: $0.end, text: $0.text)
                }
            } else {
                let lines = subtitles[clip.sourceURL]?.lines ?? []
                if lines.isEmpty {
                    let frame = state.frameRate.secondsPerFrame
                    let trimmedHead = scope.contains(clip.timelineStart) && audible(clip, near: clip.timelineStart, config: config) && !AIInspectionSpeech.isFileEdge(clip, start: true, tolerance: frame)
                    let trimmedTail = scope.contains(clip.timelineEnd) && audible(clip, near: clip.timelineEnd, config: config) && !AIInspectionSpeech.isFileEdge(clip, start: false, tolerance: frame)
                    let cutaway = cuts.contains { scope.contains($0) && $0 > clip.timelineStart && $0 < clip.timelineEnd && audible(clip, near: $0, config: config) }
                    if trimmedHead || trimmedTail || cutaway { unchecked.insert(clip.id) }
                }
                result += lines.map {
                    Spoken(clip: clip, from: clip.timelineTime(atSource: $0.span.lowerBound),
                           to: clip.timelineTime(atSource: $0.span.upperBound), text: $0.text)
                }
            }
        }
        return result
    }

    static func findings(_ spoken: [Spoken], state: TimelineState, scope: AIInspection.Scope, config: AudioEngineConfig) -> [AIInspection.Finding] {
        let pictures = AIInspectionPicture.visiblePictures(state, from: 0, to: state.duration)
        let frame = state.frameRate.secondsPerFrame
        var result: [AIInspection.Finding] = []
        var seen = Set<String>()
        for line in spoken {
            let clip = line.clip
            var cuts: [(Double, [UUID], String)] = []
            for at in [clip.timelineStart, clip.timelineEnd] {
                let source = clip.sourceTime(atTimeline: at)
                let continuous = state.allClips.contains { other in
                    other.id != clip.id && other.sourceURL == clip.sourceURL && audible(other, near: at, config: config)
                        && abs(other.speed - clip.speed) < 1e-9
                        && ((abs(other.timelineEnd - at) < frame / 2 && abs(other.sourceStart + other.sourceDuration - source) < frame)
                            || (abs(other.timelineStart - at) < frame / 2 && abs(other.sourceStart - source) < frame))
                }
                if !continuous { cuts.append((at, [clip.id], "The source is cut before this sentence has finished")) }
            }
            for picture in pictures where picture.id != clip.id {
                for at in [picture.timelineStart, picture.timelineEnd] where at > clip.timelineStart && at < clip.timelineEnd {
                    cuts.append((at, [clip.id, picture.id], "A picture cut falls inside a continuing sentence"))
                }
            }
            for (at, items, why) in cuts where scope.contains(at) && at > line.from + frame && at < line.to - frame && audible(clip, near: at, config: config) {
                let key = "\(clip.id):\(FrameGrid(state.frameRate).frame(containing: at))"
                guard seen.insert(key).inserted else { continue }
                result.append(.init(kind: "sentence_cut", from: at, to: at,
                    reason: "\(why): \"\(line.text.prefix(160))\". Review whether the cutaway or unfinished sentence is intentional.",
                    items: items, details: ["sentence_from": .number(line.from), "sentence_to": .number(line.to)]))
            }
        }
        return result
    }
    private static func audible(_ clip: EditClip, near time: Double, config: AudioEngineConfig) -> Bool {
        let pad = min(0.01, clip.timelineDuration / 2)
        let inside = min(max(time, clip.timelineStart + pad), clip.timelineEnd - pad)
        return config.master > 0 && config.tracks.contains { track in
            track.fader > 0 && track.segments.contains {
                $0.clipID == clip.id && inside >= $0.start && inside < $0.end
                    && $0.gain.gain(at: inside) * track.fader * config.master > 0.1
            }
        }
    }

}

import Foundation

// MARK: - Ducking under speech: which clips dip, and the whole call on a state (pure)
//
// Owns (MCP-29): the clips that dip under the voice track's lines — every audible clip (has sound, not muted, not hidden, on a
// track that is not hidden) on every other track, or only on the tracks the AI names; never the speech itself (a voice whose
// sound sits on another track, separated from its picture, is still the voice). Each is drawn by SpeechDuckCurve; a clip whose
// line comes out the same (ducked again with the same depth, or depth 0 where nothing dips) is left untouched, so calling again
// changes nothing. Also the lines of a voice without a transcript, from its waveform's windows by VoiceLines' rule.
// Not here: reading transcripts and waveforms (SpeechDuckLines), the tool and its result (AISpeechDuckTool).
// Rules: docs/architecture/audio-volume-curve.md section 5.

enum SpeechDuckPlanner {
    /// The voice's lines (timeline seconds) and where they came from (filled by SpeechDuckLines).
    struct Speech: Equatable, Sendable {
        var lines: [ClosedRange<Double>] = []
        /// The sounds the lines came from: never ducked.
        var clips: Set<UUID> = []
        var fromTranscript: [UUID] = []
        var fromPauses: [UUID] = []
        /// Camera sound without a cached transcript: no lines from it.
        var noTranscript: [UUID] = []
        /// Sound files SkyCut could not read.
        var unreadable: [UUID] = []
    }

    struct Target: Equatable, Sendable {
        var id: UUID
        var track: TrackSlot
    }

    struct Outcome: Equatable, Sendable {
        var id: UUID
        var track: TrackSlot
        var result: SpeechDuckCurve.Result
        /// The clip's line changed (false: it already sat that way).
        var changed: Bool
    }

    /// Every track, V1 first, then V2…, then A1…
    static func slots(in state: TimelineState) -> [TrackSlot] {
        [.main] + state.overlayTracks.indices.map { TrackSlot.overlay($0) } + state.audioTracks.indices.map { TrackSlot.audio($0) }
    }

    /// The clips that may dip: audible clips on the other tracks (only `only` when given), never one of `speech`.
    static func targets(in state: TimelineState, voice: TrackSlot, speech: Set<UUID>, only: Set<TrackSlot>?) -> [Target] {
        slots(in: state).filter { $0 != voice && (only?.contains($0) ?? true) && !state.isLaneHidden($0) }.flatMap { slot in
            state[track: slot].filter { clip in
                !speech.contains(clip.id) && clip.hasAudio && !clip.isMuted && !clip.isHidden
                    && !(clip.volume == 0 && clip.volumeCurve.isEmpty)
            }.map { Target(id: $0.id, track: slot) }
        }
    }

    /// Draws the dips into `targets` on `state`.
    static func run(_ windows: [SpeechDuck.Window], depth: Double, targets: [Target], in state: inout TimelineState) -> [Outcome] {
        targets.compactMap { target in
            guard let before = state.clip(with: target.id) else { return nil }
            var clip = before
            let result = SpeechDuckCurve.duck(&clip, under: windows, depth: depth)
            let changed = !sameLine(before.volumeCurve, clip.volumeCurve, tolerance: VolumeCurveEditing.sourceTolerance(speed: clip.speed))
            if changed { state.update(target.id) { $0 = clip } }
            return Outcome(id: target.id, track: target.track, result: result, changed: changed)
        }
    }

    /// The same keys within float noise: redrawing a dip that is already there round-trips times through the clip's speed.
    static func sameLine(_ a: KeyframeTrack, _ b: KeyframeTrack, tolerance: Double) -> Bool {
        guard a.keys.count == b.keys.count else { return false }
        return zip(a.keys, b.keys).allSatisfy { abs($0.time - $1.time) < tolerance && abs($0.value - $1.value) < 1e-6 }
    }

    /// The lines of a voice without a transcript: VoiceLines' rule on the levels of its waveform's windows over the clip
    /// (`windows` in source seconds, each nominally `windowSeconds` long), in timeline seconds.
    static func lines(fromPauses windows: [AIAudioLevels.Window], of clip: EditClip, windowSeconds: Double) -> [ClosedRange<Double>] {
        guard !windows.isEmpty, windowSeconds > 0 else { return [] }
        let levels = windows.map { 10 * log10($0.meanSquare + 1e-24) }
        return VoiceLines.stretches(levels: levels, frameSeconds: windowSeconds).map { range in
            clip.timelineTime(atSource: windows[range.lowerBound].start)...clip.timelineTime(atSource: windows[range.upperBound - 1].end)
        }
    }
}

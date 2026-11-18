import Foundation
import SrtFlowMCPKit

// MARK: - The second tier's evidence for one delivery report (preparation; the checks themselves are pure)
//
// Owns: one frozen preparation per inspection, the media reads the second-tier checks need, all on MediaReadQueue.export like the
// first tier's measurement (the export's audio configuration, offline, never the preview's engine):
// - what each sound is (AIDeliverySoundRoles, with the AI's `sounds`), where the picture changes (AIDeliveryCutJumps.pictureCuts);
// - the timeline split by role group, per frame, and the music accents (AIDeliverySoundLevels);
// - the voice check's lines (AIDeliveryVoice / AIListenVoiceMeasure) over the checked range;
// - each sound that may drag past its picture, rendered on its own (AIDeliveryLinger).
// It never edits the project. What could not be measured goes into `limitations` (the report's coverage is then incomplete).
// The registry entries reading this: cut_jumps, lingers, voice, music_swell (AIDeliveryChecks).
// Rules: docs/architecture/finished-video-inspection.md, "Second-tier sound checks".

struct AIDeliverySound: Sendable {
    var roles: AIDeliverySoundRoles = .empty
    var cuts: [AIDeliveryCutJumps.Cut] = []
    var sounds: [AIDeliveryCutJumps.Sound] = []
    /// Where lines spoken in a picture's own sound (camera role) start or end (timeline seconds), from transcripts or
    /// provenance-bearing subtitles.
    var cameraSpeech: [Double] = []
    var levels: AIDeliverySoundLevels = .empty
    var voice: AIDeliveryVoice.Outcome?
    var lingers: [AIDeliveryLinger.Measured] = []
    var limitations: [String] = []
    var duration = 0.0

    static let empty = AIDeliverySound()

    @MainActor
    static func prepare(_ state: TimelineState, request: AIDeliverySoundRoles.Request, scope: AIInspection.Scope,
                        spoken: [AIDeliverySentences.Spoken], token: ExportCancellationToken) async throws -> AIDeliverySound {
        let layout = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        var prepared = AIDeliverySound()
        prepared.duration = state.duration
        guard layout.hasSound else { return prepared }
        let roles = AIDeliverySoundRoles.assign(request, state: state, config: layout)
        prepared.roles = roles
        prepared.cuts = AIDeliveryCutJumps.pictureCuts(state)
        prepared.sounds = layout.tracks.flatMap(\.segments).map { segment in
            let fade = state.clip(with: segment.clipID)?.fadeOutDuration ?? 0
            return AIDeliveryCutJumps.Sound(id: segment.clipID, role: roles.role(of: segment.clipID), start: segment.start,
                                            end: segment.end, fadeOutStart: segment.end - fade)
        }
        // A line's start or end counts only where that clip is heard saying it (a file's lines map onto every clip that uses it).
        let half = state.frameRate.secondsPerFrame / 2
        prepared.cameraSpeech = spoken.filter { roles.role(of: $0.clip.id) == .camera }.flatMap { line in
            [line.from, line.to].filter { $0 >= line.clip.timelineStart - half && $0 <= line.clip.timelineEnd + half }
        }
        let ids = AIShortIDs(state: state)
        if !roles.unmeasurableVoice.isEmpty {
            prepared.limitations.append("Voice clarity was not measured for " + roles.unmeasurableVoice.map(ids.short).sorted().joined(separator: ", ")
                + ": a voice needs an audio track of its own (only voice clips on it) to be measured.")
        }
        let voicePlan = AIDeliveryVoice.plan(roles, state: state, layout: layout, scope: scope)
        if let note = voicePlan.limitation { prepared.limitations.append(note) }
        let lingers = AIDeliveryLinger.candidates(state, config: layout, roles: roles, cuts: prepared.cuts)
        if lingers.more > 0 {
            prepared.limitations.append("Only the first \(AIDeliveryLinger.maxCandidates) sounds past their picture were measured; inspect a narrower from/to for the other \(lingers.more).")
        }
        let grid = MixFrameGrid(fps: state.frameRate.fps)
        let frames = frameRange(scope, grid: grid, config: layout)
        let windows = prepared.cuts.filter { scope.contains($0.time) }
            .compactMap { AIDeliveryCutJumps.windows(at: $0.time, duration: state.duration, fps: grid.fps) }.flatMap { [$0.0, $0.1] }
        let plan = voicePlan.plan, candidates = lingers.found
        let measured = try await MediaReadQueue.run(on: MediaReadQueue.export) {
            Result { () throws -> Measured in
                let config = AudioEngineConfig.make(from: state)
                let stop = { token.isCancelled }
                return Measured(
                    levels: try AIDeliverySoundLevels.measure(config, roles: roles, grid: grid, frames: frames, windows: windows,
                                                              isCancelled: stop),
                    lines: try plan.map { try AIListenVoiceMeasure.measure($0, config: config, isCancelled: stop) },
                    lingers: try AIDeliveryLinger.measure(candidates, config: config, grid: grid, isCancelled: stop))
            }
        }.get()
        prepared.levels = measured.levels
        if let plan, let lines = measured.lines { prepared.voice = AIDeliveryVoice.outcome(plan, lines: lines, state: state) }
        prepared.lingers = measured.lingers
        return prepared
    }

    private struct Measured: Sendable {
        let levels: AIDeliverySoundLevels
        let lines: [AIListenVoiceMeasure.Line]?
        let lingers: [AIDeliveryLinger.Measured]
    }

    /// The frames the checks read: the checked range with a second either side (the windows reach 0.32 s past a cut, a running
    /// median half a second past a line).
    private static func frameRange(_ scope: AIInspection.Scope, grid: MixFrameGrid, config: AudioEngineConfig) -> Range<Int> {
        let total = MixMeasurement.frameCount(config, grid: grid)
        let from = (scope.ranges.map(\.lowerBound).min() ?? 0) - 1, to = (scope.ranges.map(\.upperBound).max() ?? config.duration) + 1
        let first = max(0, grid.frame(containing: max(0, from)))
        return first ..< max(first, min(total, grid.frame(endingAt: min(config.duration, to))))
    }

    // MARK: Report

    /// What SkyCut took each track's sounds to be, for the AI to check and correct with `sounds`.
    var rolesJSON: JSONValue { roles.summary }
}

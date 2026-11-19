import Foundation
import SrtFlowMCPKit

// MARK: - A sound jumping out of the mix away from any cut (MCP-40 tier 2; a reminder, report only)
//
// Owns `audio_abrupt`, the production research's check_project.py rule 12 (the preview board's pop): an effect or an object
// (AIDeliverySoundRoles) whose loudest 0.1 s cell is above −30 dBFS and 15 dB or more over everything else around it — the
// median, over the 3 s each side, of the timeline's mix without it (the role groups added up, minus the sound itself) — and
// whose peak is more than 6 frames from any picture event (AIDeliveryMusicEdges.pictureEvents). The research counted cuts only;
// titles count here too, since the shared rules land a title on a big hit (Title cards).
// Each candidate is rendered on its own (its one segment with its track's fader and the master, DeliveryStemPower) over its
// own span: at most `maxCandidates` inside the checked range, the rest in limitations.
// The line is the research's (no case on the human film; delivery-checks.md in the research folder): a reminder, not
// validated; mark a deliberate hit intentional.
// Not here: the role groups' levels (AIDeliverySoundLevels), roles (AIDeliverySoundRoles).

enum AIDeliveryAbrupt {
    struct Candidate: Sendable {
        let id: UUID
        let role: DeliverySoundRole
        /// Its one segment and its track, to render it alone as the export plays it.
        let segment: AudioEngineConfig.Segment
        let track: AudioEngineConfig.Track
        /// Where its sound can last until (timeline seconds; a scene's tail included).
        let end: Double
    }

    /// One candidate measured alone: what the rule reads (no engine types, so the rule runs on made-up numbers too).
    struct Measured: Sendable {
        let id: UUID
        let role: DeliverySoundRole
        /// Its span on the timeline (seconds), where the peak is looked for.
        let start: Double
        let end: Double
        let firstFrame: Int
        /// Its power (mean square) per project frame from `firstFrame`.
        let power: [Double]
    }

    static let peakFloorDB = -30.0
    static let aboveDB = 15.0
    static let aroundSeconds = 3.0
    static let eventFrames = 6.0
    static let maxCandidates = 40

    // MARK: Candidates

    static func candidates(_ config: AudioEngineConfig, roles: AIDeliverySoundRoles,
                           scope: AIInspection.Scope) -> (found: [Candidate], more: Int) {
        var found: [Candidate] = []
        for track in config.tracks {
            for segment in track.segments {
                let role = roles.role(of: segment.clipID)
                guard role == .effects || role == .object, scope.intersects(segment.start, segment.end) else { continue }
                let tail = segment.scene == nil ? 0 : SceneRecipe.maximumTail
                found.append(Candidate(id: segment.clipID, role: role, segment: segment, track: track, end: segment.end + tail))
            }
        }
        found = found.enumerated().sorted { ($0.element.segment.start, $0.offset) < ($1.element.segment.start, $1.offset) }.map(\.element)
        return (Array(found.prefix(maxCandidates)), max(0, found.count - maxCandidates))
    }

    // MARK: Measuring (blocking: MediaReadQueue)

    static func measure(_ candidates: [Candidate], config: AudioEngineConfig, grid: MixFrameGrid,
                        isCancelled: () -> Bool) throws -> [Measured] {
        let total = MixMeasurement.frameCount(config, grid: grid)
        return try candidates.compactMap { candidate in
            let first = grid.frame(containing: candidate.segment.start)
            let last = min(total, grid.frame(endingAt: min(candidate.end, config.duration)))
            guard last > first else { return nil }
            let track = AudioEngineConfig.Track(name: candidate.track.name, meterKey: candidate.track.meterKey, fader: candidate.track.fader,
                                                segments: [candidate.segment])
            let alone = AudioEngineConfig(tracks: [track], master: config.master, duration: config.duration)
            let powers = try DeliveryStemPower.measure(alone, layers: [AudioStemLayer(name: "sound", tracks: [0])], grid: grid,
                                                       frames: first ..< last, isCancelled: isCancelled)
            return Measured(id: candidate.id, role: candidate.role, start: candidate.segment.start, end: candidate.segment.end,
                            firstFrame: first, power: powers[0])
        }
    }

    // MARK: The rule

    static func findings(_ measured: [Measured], levels: AIDeliverySoundLevels, events: [Double],
                         scope: AIInspection.Scope) -> [AIInspection.Finding] {
        let cells = DeliveryCells(levels), around = DeliveryCells.count(aroundSeconds)
        let fps = Double(levels.grid.fps)
        return measured.compactMap { entry in
            func own(_ cell: Int) -> Double {
                AIDeliverySoundLevels.meanPower(grid: levels.grid, from: DeliveryCells.from(cell), to: DeliveryCells.to(cell)) { frame in
                    let index = frame - entry.firstFrame
                    return entry.power.indices.contains(index) ? entry.power[index] : 0
                }
            }
            let span = DeliveryCells.cell(containing: entry.start) ..< DeliveryCells.cell(containing: entry.end)
            guard let peak = span.max(by: { own($0) < own($1) }) else { return nil }
            let peakDB = AIDeliverySoundLevels.db(own(peak))
            let at = DeliveryCells.from(peak)
            guard peakDB >= peakFloorDB, scope.contains(at) else { return nil }
            let window = max(cells.range.lowerBound, peak - around) ..< min(cells.range.upperBound, peak + around + 1)
            guard !window.isEmpty else { return nil }
            let rest = window.map { cell in
                AIDeliverySoundLevels.db(max(0, levels.meanPower(from: DeliveryCells.from(cell), to: DeliveryCells.to(cell)) - own(cell)))
            }
            let base = AIDeliveryMusic.median(rest)
            guard peakDB - base >= aboveDB, !events.contains(where: { abs(at - $0) * fps <= eventFrames }) else { return nil }
            return AIInspection.Finding(
                kind: "audio_abrupt", from: at, to: at + DeliveryCells.seconds,
                reason: String(format: "A reminder: this %@ peaks at %.0f dBFS, %.0f dB over everything else around it (the median of the "
                    + "%.0f s each side), away from any cut or title, so it may jump out. Lower it, put it on a cut, or mark it intentional.",
                    entry.role == .object ? "sound of a thing in the picture" : "effect", peakDB, peakDB - base, aroundSeconds),
                items: [entry.id],
                details: ["peak_db": AIDeliveryMusic.tenths(peakDB), "around_db": AIDeliveryMusic.tenths(base),
                          "above_db": AIDeliveryMusic.tenths(peakDB - base)])
        }
    }
}

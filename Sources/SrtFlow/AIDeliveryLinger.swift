import Foundation
import SrtFlowMCPKit

// MARK: - A sound dragging past its picture (MCP-38; report only)
//
// Owns: which sounds belong to a picture that cuts away while they still sound, measuring each one on its own, and the rule
// (production feedback MCP-38, preview board v1.2; the user heard the bus's metal clang ring 6 frames into the overpass shot):
// - **object** (`sounds` names it: a thing in the picture): it belongs to the shot it sounds under longest (one brought in a few
//   frames early, a lead, belongs to the next shot: the human editor does that often). Once that shot cuts away it may sound at
//   most `allowedFrames` frames above `audibleDB` (counted from the cut's frame while it stays above).
// - **camera** sound detached to an audio track (its picture is the linked one, or the picture of the same file under its start):
//   once that picture cuts away, at most `allowedFrames` frames may be `overBedDB` above everything else heard on the far side
//   (the bed leaves out the sound itself and the picture's other sounds: its own recording and objects that started in it).
// Not reported: the next picture is the same file (the thing is still on screen); a camera sound attached to its picture (it
// ends with it); ambience, effects, music and voice (an ambience or a hit's tail may carry on: a lag is a normal way to cross a
// cut). Whether the next shot shows the same thing is not knowable here: mark it intentional (one line why).
// Each candidate is rendered on its own (DeliveryStemSplit, DeliveryStemPower) over its frames after the cut; at most
// `maxCandidates`.
// Thresholds (2 frames, −50 dBFS, 6 dB) follow the user's one case and the board's existing lines; not validated on other films.
// Not here: the picture cuts (AIDeliveryCutJumps.pictureCuts), roles (AIDeliverySoundRoles).

enum AIDeliveryLinger {
    enum Kind: String, Sendable { case object, camera }

    struct Candidate: Sendable {
        let kind: Kind
        let sound: UUID
        let picture: UUID
        let cut: Double
        /// Where its sound can last until (timeline seconds; a scene's tail included).
        let end: Double
        /// Camera: clips left out of the far side's bed besides the sound itself.
        let leftOut: Set<UUID>
    }

    struct Measured: Sendable {
        let candidate: Candidate
        let firstFrame: Int
        /// Per frame from the cut's frame on (dBFS): the sound alone, and the bed (camera only).
        let sound: [Double]
        let bed: [Double]
    }

    static let audibleDB = -50.0
    static let overBedDB = 6.0
    static let allowedFrames = 2
    static let maxCandidates = 40

    // MARK: Candidates

    @MainActor
    static func candidates(_ state: TimelineState, config: AudioEngineConfig, roles: AIDeliverySoundRoles,
                           cuts: [AIDeliveryCutJumps.Cut]) -> (found: [Candidate], more: Int) {
        let pictures = AIInspectionPicture.visiblePictures(state, from: 0, to: state.duration)
        let half = state.frameRate.secondsPerFrame / 2
        let shots = spans(cuts, duration: state.duration)
        var found: [Candidate] = []
        for track in config.tracks {
            for segment in track.segments {
                guard let clip = state.clip(with: segment.clipID) else { continue }
                let role = roles.role(of: clip.id)
                let tail = segment.scene == nil ? 0 : SceneRecipe.maximumTail
                switch role {
                case .object:
                    // It belongs to the shot it sounds in longest: a sound brought in early (a lead) belongs to the next shot.
                    guard let shot = shots.max(by: { overlap($0, segment) < overlap($1, segment) }), overlap(shot, segment) > 0,
                          let picture = shot.picture, segment.end > shot.to + half,
                          let cut = cuts.first(where: { abs($0.time - shot.to) < half }), !sameFile(cut, pictures) else { continue }
                    found.append(Candidate(kind: .object, sound: clip.id, picture: picture, cut: cut.time,
                                           end: segment.end + tail, leftOut: []))
                case .camera where track.name.hasPrefix("A"):
                    let own = pictures.filter { ($0.linkGroup != nil && $0.linkGroup == clip.linkGroup) || $0.sourceURL == clip.sourceURL }
                    guard let picture = own.first(where: { $0.timelineStart <= segment.start + half && $0.timelineEnd > segment.start + half }),
                          segment.end > picture.timelineEnd + half,
                          let cut = cuts.first(where: { $0.outgoing == picture.id && abs($0.time - picture.timelineEnd) < half }),
                          !sameFile(cut, pictures) else { continue }
                    let leftOut = Set(config.tracks.flatMap(\.segments).filter { other in
                        guard other.clipID != clip.id, let item = state.clip(with: other.clipID) else { return false }
                        let otherRole = roles.role(of: other.clipID)
                        return (otherRole == .camera && item.sourceURL == picture.sourceURL)
                            || (otherRole == .object && other.start >= picture.timelineStart - half && other.start < picture.timelineEnd)
                    }.map(\.clipID))
                    found.append(Candidate(kind: .camera, sound: clip.id, picture: picture.id, cut: cut.time,
                                           end: segment.end + tail, leftOut: leftOut))
                default:
                    continue
                }
            }
        }
        // By cut, then in timeline order (tracks top to bottom): the same report every time.
        found = found.enumerated().sorted { ($0.element.cut, $0.offset) < ($1.element.cut, $1.offset) }.map(\.element)
        return (Array(found.prefix(maxCandidates)), max(0, found.count - maxCandidates))
    }

    /// The stretches between picture cuts and the picture on each (nil = black).
    static func spans(_ cuts: [AIDeliveryCutJumps.Cut], duration: Double) -> [(from: Double, to: Double, picture: UUID?)] {
        var result: [(from: Double, to: Double, picture: UUID?)] = []
        var start = 0.0
        for cut in cuts.sorted(by: { $0.time < $1.time }) {
            result.append((start, cut.time, cut.outgoing))
            start = cut.time
        }
        if let last = cuts.max(by: { $0.time < $1.time }) { result.append((start, duration, last.incoming)) }
        return result
    }

    private static func overlap(_ shot: (from: Double, to: Double, picture: UUID?), _ segment: AudioEngineConfig.Segment) -> Double {
        max(0, min(shot.to, segment.end) - max(shot.from, segment.start))
    }

    /// The next picture is the same file: whatever made the sound is still on screen.
    private static func sameFile(_ cut: AIDeliveryCutJumps.Cut, _ pictures: [EditClip]) -> Bool {
        guard let outgoing = cut.outgoing.flatMap({ id in pictures.first { $0.id == id } }),
              let incoming = cut.incoming.flatMap({ id in pictures.first { $0.id == id } }) else { return false }
        return outgoing.sourceURL == incoming.sourceURL
    }

    // MARK: Measuring (blocking: MediaReadQueue)

    private enum Part: String { case sound, bed, rest }

    static func measure(_ candidates: [Candidate], config: AudioEngineConfig, grid: MixFrameGrid,
                        isCancelled: () -> Bool) throws -> [Measured] {
        let total = MixMeasurement.frameCount(config, grid: grid)
        return try candidates.compactMap { candidate in
            let first = grid.frame(containing: candidate.cut)
            let last = min(total, grid.frame(endingAt: min(candidate.end, config.duration)))
            guard last > first else { return nil }
            let wanted: [Part] = candidate.kind == .camera ? [.sound, .bed] : [.sound]
            let split = DeliveryStemSplit.split(config, wanted: wanted, name: \.rawValue) { segment in
                segment.clipID == candidate.sound ? .sound : candidate.leftOut.contains(segment.clipID) ? .rest : .bed
            }
            let powers = try DeliveryStemPower.measure(split.config, layers: split.layers.map(\.layer), grid: grid, frames: first ..< last,
                                                       isCancelled: isCancelled)
            func levels(_ part: Part) -> [Double] {
                guard let index = split.layers.firstIndex(where: { $0.key == part }) else { return Array(repeating: -120, count: last - first) }
                return powers[index].map(AIDeliverySoundLevels.db)
            }
            return Measured(candidate: candidate, firstFrame: first, sound: levels(.sound), bed: candidate.kind == .camera ? levels(.bed) : [])
        }
    }

    // MARK: The rule

    /// Frames over the line after the cut: an object while it stays above `audibleDB`; a camera sound wherever it stands
    /// `overBedDB` above the far side's bed.
    static func frames(_ measured: Measured) -> Int {
        switch measured.candidate.kind {
        case .object:
            return measured.sound.prefix { $0 > audibleDB }.count
        case .camera:
            return zip(measured.sound, measured.bed).filter { $0 > audibleDB && $0 >= $1 + overBedDB }.count
        }
    }

    static func findings(_ measured: [Measured], grid: MixFrameGrid, scope: AIInspection.Scope) -> [AIInspection.Finding] {
        measured.compactMap { entry in
            let count = frames(entry)
            let candidate = entry.candidate
            guard count > allowedFrames, scope.contains(candidate.cut) else { return nil }
            let loudest = entry.sound.prefix(max(count, 1)).max() ?? -120
            let what = candidate.kind == .object
                ? "This sound belongs to the picture it starts in; that picture cuts away here but it keeps sounding %d frames above %.0f dBFS"
                : "This is the picture's own sound; after its picture cuts away it stands %.0f dB or more over the next shot's sound for %d frames"
            let text = candidate.kind == .object
                ? String(format: what, count, audibleDB) : String(format: what, overBedDB, count)
            return AIInspection.Finding(
                kind: "audio_linger", from: candidate.cut, to: candidate.cut + Double(count) / Double(grid.fps),
                reason: text + String(format: " (loudest %.0f dBFS). End or fade it within %d frames of the cut, or mark it intentional "
                    + "(the next shot shows the same thing, a tail meant to ring on).", loudest, allowedFrames),
                items: [candidate.sound, candidate.picture],
                details: ["linger_frames": .number(Double(count)), "sound": .string(candidate.kind.rawValue)])
        }
    }
}

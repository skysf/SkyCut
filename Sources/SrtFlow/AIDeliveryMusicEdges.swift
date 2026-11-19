import Foundation
import SrtFlowMCPKit

// MARK: - Music starting or stopping hard away from anything in the picture (MCP-40 tier 2; report only)
//
// Owns `audio_music_edge`, the production research's check_project.py rule 6 (the preview board's music_edge), and the picture
// events it reads, which the abrupt-sound row reads too (`pictureEvents`): every picture cut (AIDeliveryCutJumps.pictureCuts,
// cuts to and from black included), where the first picture appears, and where a title (a visible text) appears. The research
// also counted events inside a shot (a ship hitting ice), which SkyCut can't know (MCP-40's third tier).
// The rule, per music clip (what AIDeliverySoundRoles takes as music), at its start and at its end:
// - not judged where it fades (0.3 s or more), at the film's first 0.05 s or last 0.1 s, where the same file carries on in the
//   next clip (one piece split in two), or where another music clip plays across the edge (0.3 s each side) and is heard there
//   above −40 dBFS (a layer added or taken away over a bed);
// - not judged where it is quiet: the music group stays under −40 dBFS over the 0.3 s inside the edge;
// - otherwise the nearest picture event more than 6 frames away is reported. The human film had one (1:37.23, a piece entering
//   17 frames before a cut, the research: "maybe on a hit in the music itself — listen"): mark such ones intentional.
// Thresholds are the research's (delivery-checks.md in the research folder); not validated across genres.
// Not here: music missing or late (AIDeliveryMusic), measuring (AIDeliverySoundLevels).

enum AIDeliveryMusicEdges {
    /// One music clip as the export plays it, with what the rule needs from the clip itself.
    struct Clip: Sendable, Equatable {
        let id: UUID
        let url: URL
        let start: Double
        let end: Double
        /// Its effective fade-in and fade-out (timeline seconds; `EditClip.audioFades`).
        let fadeIn: Double
        let fadeOut: Double
    }

    static let fadeSeconds = 0.3
    static let headSeconds = 0.05
    static let tailSeconds = 0.1
    /// The same file carrying on within this (seconds) is one piece split in two.
    static let joinSeconds = 0.1
    /// Quieter than this (dBFS) at the edge is not a hard edge; another music this loud across it is a bed.
    static let loudDB = -40.0
    static let edgeSeconds = 0.3
    static let eventFrames = 6.0

    // MARK: Inputs (frozen state)

    /// Where something happens in the picture: cuts, the first picture appearing, titles appearing (timeline seconds, sorted).
    @MainActor
    static func pictureEvents(_ state: TimelineState, cuts: [AIDeliveryCutJumps.Cut]) -> [Double] {
        var times = cuts.map(\.time)
        if let first = AIInspectionPicture.visiblePictures(state, from: 0, to: state.duration).map(\.timelineStart).min() {
            times.append(first)
        }
        times += state.renderedTextOverlays.filter { $0.number != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.timelineStart)
        return times.sorted()
    }

    /// The music clips among the sounds the export plays.
    static func clips(_ state: TimelineState, sounds: [AIDeliveryCutJumps.Sound]) -> [Clip] {
        sounds.filter { $0.role == .music }.compactMap { sound in
            guard let clip = state.clip(with: sound.id) else { return nil }
            let fades = clip.audioFades
            return Clip(id: sound.id, url: clip.sourceURL, start: sound.start, end: sound.end, fadeIn: fades.fadeIn, fadeOut: fades.fadeOut)
        }
    }

    // MARK: The rule

    static func findings(_ clips: [Clip], events: [Double], levels: AIDeliverySoundLevels, duration: Double,
                         scope: AIInspection.Scope) -> [AIInspection.Finding] {
        let fps = Double(levels.grid.fps)
        var result: [AIInspection.Finding] = []
        for clip in clips {
            for entering in [true, false] {
                let time = entering ? clip.start : clip.end
                let fade = entering ? clip.fadeIn : clip.fadeOut
                guard scope.contains(time), fade < fadeSeconds, time > headSeconds, time < duration - tailSeconds,
                      !continues(clip, entering: entering, among: clips),
                      !overBed(clip, at: time, entering: entering, among: clips, levels: levels) else { continue }
                let inside = entering ? (time, time + edgeSeconds) : (time - edgeSeconds, time)
                let loudest = stride(from: inside.0, to: inside.1 - 1e-9, by: DeliveryCells.seconds)
                    .map { levels.db(.music, from: $0, to: min(inside.1, $0 + DeliveryCells.seconds)) }.max() ?? -120
                guard loudest >= loudDB else { continue }
                let nearest = events.min { abs($0 - time) < abs($1 - time) }
                let frames = nearest.map { ((time - $0) * fps).rounded() }
                if let frames, abs(frames) <= eventFrames { continue }
                let near = nearest.map { String(format: "%+.0f frames from the nearest picture event (%.2f s: a cut or a title)", frames ?? 0, $0) }
                    ?? "with no cut or title anywhere"
                var details: [String: JSONValue] = ["edge": .string(entering ? "in" : "out")]
                if let nearest, let frames { details["event_at"] = AIFormat.seconds(nearest); details["frames_from_event"] = .number(frames) }
                result.append(AIInspection.Finding(
                    kind: "audio_music_edge", from: time, to: time,
                    reason: String(format: "Music %@ hard here (no %@, %.0f dBFS), %@: a hard music %@ belongs on a cut or a title. Move it "
                        + "there, fade it over %.1f s or more, or mark it intentional (a hit in the music itself).",
                        entering ? "enters" : "stops", entering ? "fade-in" : "fade-out", loudest, near,
                        entering ? "entry" : "stop", fadeSeconds),
                    items: [clip.id], details: details))
            }
        }
        return result
    }

    /// The same file carrying on in the next clip (or carried on from the previous one): one piece split in two.
    private static func continues(_ clip: Clip, entering: Bool, among clips: [Clip]) -> Bool {
        clips.contains { other in
            other.id != clip.id && other.url == clip.url
                && abs(entering ? other.end - clip.start : other.start - clip.end) < joinSeconds
        }
    }

    /// Another music clip playing across the edge and heard there on its own: before an entry, after a stop.
    private static func overBed(_ clip: Clip, at time: Double, entering: Bool, among clips: [Clip],
                                levels: AIDeliverySoundLevels) -> Bool {
        guard clips.contains(where: { $0.id != clip.id && $0.start < time - edgeSeconds && $0.end > time + edgeSeconds }) else { return false }
        let other = entering ? levels.db(.music, from: time - DeliveryCells.seconds, to: time)
            : levels.db(.music, from: time, to: time + DeliveryCells.seconds)
        return other > loudDB
    }
}

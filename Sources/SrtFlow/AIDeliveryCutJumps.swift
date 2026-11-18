import Foundation
import SrtFlowMCPKit

// MARK: - A hard sound jump at a cut with nothing covering it (MCP-37; report only)
//
// Owns: where the picture changes (`pictureCuts`: the top picture that fills the frame, V1 or a full-frame upper clip, differs on
// the two sides; an upper clip counts only while it is opaque there — no alpha in its media, full opacity, outside its fade /
// entrance / exit window (`hidesBelow`) —, else the cut under it stays; black counts as a picture; a split of one continuous take
// is not a cut) and the rule. At each cut the sound of
// the place (AIDeliverySoundLevels' place group: a picture's own sound, ambience, objects, unnamed files) is measured in
// CutSoundWindows' 0.3 s on each side (the windows set_transition sound measures; the human film and the preview board too),
// over the full band and above 200 Hz (DeliveryWindowCollector). A jump of `jumpDB` or more, with the louder side heard, is
// reported unless something covers it (joins-human.md: 23 of the human film's 24 such cuts were covered; uncovered ones differ
// by 3.4 dB at most):
// - a bed: voice, music or effects sounding from 0.3 s before to 0.3 s after the cut, at the cut no more than
//   `CutSoundLevelPlan.bedMargin` under the louder side and above `bedFloorDB` (the same rule set_transition sound=bed meets);
// - a music accent within ±3 frames (MusicAccents); music entering or stopping (end or fade-out start) within ±2 frames,
//   heard on that side (above −45 dBFS over the 0.1 s cell one cell away from the cut, the research's cells);
// - an effect starting within ±3 frames at most 3 dB under the louder side (a hit), or ending within ±2 frames at most 6 dB under
//   it (a riser reaching its top);
// - a line in a picture's own sound (a transcript or narration subtitle) starting or ending within 0.35 s of the cut.
// A narration line beginning at the cut (−2 to +4 frames) is noted, never a cover (the user's "incubator → subway" had only that).
// Thresholds come from one human film (45 cuts) and the two cuts the user named (production feedback MCP-37); not validated
// across genres, hence report only, and intentional marks apply.
// Not here: measuring (AIDeliverySoundLevels), roles (AIDeliverySoundRoles), the fix (set_transition sound, docs/architecture/cut-sound.md).

enum AIDeliveryCutJumps {
    /// Where the picture changes: the top full-frame picture before and after (nil = black).
    struct Cut: Sendable, Equatable {
        let time: Double
        let outgoing: UUID?
        let incoming: UUID?
    }

    /// One clip's sound as the export plays it, with its role.
    struct Sound: Sendable {
        let id: UUID
        let role: DeliverySoundRole
        let start: Double
        let end: Double
        /// Where its fade-out begins (= end without one).
        let fadeOutStart: Double
    }

    static let jumpDB = 6.0
    /// The louder side must be heard (dBFS, any band).
    static let heardDB = -45.0
    /// Silence counts as this (dBFS).
    static let floorDB = -60.0
    /// A bed must at least be above this at the cut (dBFS).
    static let bedFloorDB = -50.0
    static let accentFrames = 3.0
    static let edgeFrames = 2.0
    /// Music or a riser is "heard on that side" over this cell next to the cut, one cell away from it (seconds).
    static let heardCell = 0.1
    static let hitFrames = 3.0
    static let hitMarginDB = 3.0
    /// A line in a picture's own sound this close to the cut (seconds) jumps itself.
    static let speechSeconds = 0.35
    static let voiceHeadFrames = -2.0 ... 4.0
    static let voiceHeadDB = -40.0

    // MARK: Where the picture changes

    static func pictureCuts(_ state: TimelineState) -> [Cut] {
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        let main = state.mainHidden ? [] : ClipVisibility.visible(state.mainClips).filter { !$0.isAudioOnly }
        // Only an upper picture that fills the frame and has no transparency in its media (`sourceAlpha`: a web motion with clear
        // pixels, a transparent PNG, a ProRes 4444 with alpha) can hide the pictures under it; when it does is `hidesBelow`.
        let upper = state.overlayTracks.filter { !$0.isHidden }.map { lane in
            ClipVisibility.visible(lane.clips).filter {
                !$0.isAudioOnly && $0.sourceAlpha == .opaque && ClipCoverage.fill($0, canvas: canvas).fillsFrame
            }
        }
        let lanes: [[EditClip]] = Array(upper.reversed()) + [main]
        let duration = state.duration
        let half = state.frameRate.secondsPerFrame / 2
        let edges = lanes.flatMap { $0.flatMap { [$0.timelineStart, $0.timelineEnd] } }.filter { $0 > half && $0 < duration - half }
        let times = edges.sorted().reduce(into: [Double]()) { kept, time in
            if kept.last.map({ time - $0 >= half }) ?? true { kept.append(time) }
        }
        func top(_ time: Double) -> EditClip? {
            func shown(_ clip: EditClip) -> Bool { clip.timelineStart <= time && clip.timelineEnd > time }
            for lane in upper.reversed() { if let clip = lane.first(where: shown), hidesBelow(clip, at: time) { return clip } }
            return main.first(where: shown)
        }
        return times.compactMap { time in
            let before = top(time - min(half, 0.001)), after = top(time + min(half, 0.001))
            guard before?.id != after?.id, !continues(before, after, at: time) else { return nil }
            return Cut(time: time, outgoing: before?.id, incoming: after?.id)
        }
    }

    /// Whether an upper clip that fills the frame hides the pictures under it at `time`: only at full opacity (keyframed or not) and
    /// outside its fade-in / fade-out window, which its entrance and exit share (fade, rise, pop and zoom ramp the opacity from 0; a
    /// wipe reveals it). Elsewhere the layer below shows, so a cut under it is still a cut (review CXR2 R7).
    static func hidesBelow(_ clip: EditClip, at time: Double) -> Bool {
        guard clip.animatedOpacity(atTimeline: time) >= 0.999 else { return false }
        let local = time - clip.timelineStart, fades = clip.videoFades
        return local >= fades.fadeIn && local <= clip.timelineDuration - fades.fadeOut
    }

    /// The same take carrying on (a split without a change of source time or speed) is not a cut.
    private static func continues(_ before: EditClip?, _ after: EditClip?, at time: Double) -> Bool {
        guard let before, let after, before.sourceURL == after.sourceURL, abs(before.speed - after.speed) < 1e-9 else { return false }
        return abs(before.sourceTime(atTimeline: time) - after.sourceTime(atTimeline: time)) < 0.01
    }

    // MARK: The rule

    /// `speech`: where lines in a picture's own sound start or end (timeline seconds).
    static func findings(_ cuts: [Cut], levels: AIDeliverySoundLevels, sounds: [Sound], speech: [Double],
                         duration: Double, scope: AIInspection.Scope) -> [AIInspection.Finding] {
        var result: [AIInspection.Finding] = []
        for cut in cuts where scope.contains(cut.time) {
            let time = cut.time
            guard let (before, after) = windows(at: time, duration: duration, fps: levels.grid.fps) else { continue }
            func fullDB(_ window: ClosedRange<Double>) -> Double {
                max(floorDB, levels.db(.place, from: window.lowerBound, to: window.upperBound))
            }
            let full = (fullDB(before), fullDB(after))
            let high = (max(floorDB, levels.placeHighDB(before)), max(floorDB, levels.placeHighDB(after)))
            let jumpFull = full.1 - full.0, jumpHigh = high.1 - high.0
            let useHigh = abs(jumpHigh) > abs(jumpFull) + 0.05
            let jump = useHigh ? jumpHigh : jumpFull
            let loud = max(full.0, full.1)
            guard abs(jump) >= jumpDB, max(full.0, full.1, high.0, high.1) > heardDB,
                  covers(at: time, loud: loud, levels: levels, sounds: sounds, speech: speech).isEmpty else { continue }
            var details: [String: JSONValue] = [
                "jump_db": tenths(jump), "band": .string(useHigh ? "above_200_hz" : "full"),
                "place_db": [tenths(useHigh ? high.0 : full.0), tenths(useHigh ? high.1 : full.1)],
                "full_band_db": [tenths(full.0), tenths(full.1)]
            ]
            if let head = voiceHead(at: time, levels: levels, sounds: sounds) { details["voice_head_frames"] = .number(head) }
            let reason = String(
                format: "The sound of the place jumps %+.1f dB at this cut (%@, 0.3 s each side: %.1f → %.1f dBFS) and nothing covers it: "
                    + "no voice, music or effect bed within 6 dB, no music accent, music entering or stopping, hit or riser at the cut. "
                    + "Cover it with set_transition sound (crossfade, lead, lag or bed), or mark it intentional.",
                jump, useHigh ? "above 200 Hz" : "full band", useHigh ? high.0 : full.0, useHigh ? high.1 : full.1)
            result.append(.init(kind: "audio_cut_jump", from: time, to: time, reason: reason,
                                items: [cut.outgoing, cut.incoming].compactMap { $0 }, details: details))
        }
        return result
    }

    /// The 0.3 s measured on each side of a cut (CutSoundWindows), kept inside the timeline; nil when a side is under a frame.
    /// The bounds are compared as numbers before a range is built: a cut one frame from either end (a one-frame head or tail at
    /// 60 fps, 1/60 s, is shorter than the 0.02 s gap) leaves that side reversed, and a reversed ClosedRange stops the app.
    static func windows(at time: Double, duration: Double, fps: Int) -> (ClosedRange<Double>, ClosedRange<Double>)? {
        let out = CutSoundWindows.outgoing(time), into = CutSoundWindows.incoming(time)
        let before = (from: max(0, out.from), to: out.to), after = (from: into.from, to: min(duration, into.to))
        let frame = 1 / Double(fps)
        guard before.to - before.from >= frame, after.to - after.from >= frame else { return nil }
        return (before.from ... before.to, after.from ... after.to)
    }

    /// What covers the jump at `time` (empty: nothing).
    static func covers(at time: Double, loud: Double, levels: AIDeliverySoundLevels, sounds: [Sound],
                       speech: [Double]) -> [String] {
        let frame = 1 / Double(levels.grid.fps)
        let index = levels.grid.frame(containing: time)
        let span = Int((CutSoundWindows.span / frame).rounded())
        var found: [String] = []
        for group in [AIDeliverySoundLevels.Group.voice, .music, .effects] {
            let crossing = sounds.contains {
                AIDeliverySoundLevels.Group($0.role) == group
                    && $0.start <= time - CutSoundWindows.span && $0.end >= time + CutSoundWindows.span
            }
            let level = max(levels.db(group, frame: index - 1), levels.db(group, frame: index))
            if crossing, level >= loud - CutSoundLevelPlan.bedMargin, level > bedFloorDB { found.append("\(group.rawValue) bed") }
        }
        if levels.accents.contains(where: { abs($0.time - time) <= accentFrames * frame }) { found.append("music accent") }
        // "Heard on that side" over the research's 0.1 s cells next to the cut ([T + 0.1, T + 0.2) after it, [T − 0.2, T − 0.1)
        // before it): a single frame right at the cut misses music that ends with its file a few frames early.
        let afterCell = levels.db(.music, from: time + heardCell, to: time + 2 * heardCell)
        let beforeCell = { (group: AIDeliverySoundLevels.Group) in levels.db(group, from: time - 2 * heardCell, to: time - heardCell) }
        for sound in sounds where sound.role == .music {
            if abs(sound.start - time) <= edgeFrames * frame, afterCell > heardDB { found.append("music enters") }
            if min(abs(sound.end - time), abs(sound.fadeOutStart - time)) <= edgeFrames * frame, beforeCell(.music) > heardDB {
                found.append("music stops")
            }
        }
        let hit = (index ..< index + max(1, span)).map { levels.db(.effects, frame: $0) }.max() ?? -120
        for sound in sounds where sound.role == .effects {
            if abs(sound.start - time) <= hitFrames * frame, hit >= loud - hitMarginDB { found.append("hit") }
            if abs(sound.end - time) <= edgeFrames * frame, beforeCell(.effects) >= loud - CutSoundLevelPlan.bedMargin {
                found.append("riser ends")
            }
        }
        if speech.contains(where: { abs($0 - time) <= speechSeconds }) { found.append("speech in the picture") }
        return found
    }

    /// A narration line beginning at the cut (frames from the cut), noted but never a cover.
    private static func voiceHead(at time: Double, levels: AIDeliverySoundLevels, sounds: [Sound]) -> Double? {
        let frame = 1 / Double(levels.grid.fps)
        let index = levels.grid.frame(containing: time)
        let span = Int((CutSoundWindows.span / frame).rounded())
        let heard = (index ..< index + max(1, span)).map { levels.db(.voice, frame: $0) }.max() ?? -120
        guard heard > voiceHeadDB else { return nil }
        return sounds.filter { $0.role == .voice }.map { (($0.start - time) / frame).rounded() }.first { voiceHeadFrames.contains($0) }
    }

    private static func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
}

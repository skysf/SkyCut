import Foundation
import SrtFlowMCPKit

// Ducking under speech (set_track duck_others_db, MCP-29, 2026-11-18; docs/architecture/audio-volume-curve.md section 5):
// 1. Windows: down from 0.4 s before a line, full at its start, back 0.5 s after; lines leaving the layer up for less than
//    1 s share one window (nothing comes up between words or short pauses).
// 2. The curve: under a line a clip sits the depth under its own level next to the line (the edge line); calling again sets
//    the dip instead of stacking it, 0 takes it out; shapes above the edge line (a crossfade bump) stay; a window crossing the
//    clip's start takes its level from the other end; a clip wholly inside a line is left alone; the volume floor is reported;
//    a clip only the shallow start of a ramp reaches (ending in the attack, starting in the release) is set, never stacked.
// 3. Which clips dip: every audible clip on the other tracks (or only the named ones), never the speech itself.
// 4. A narration's lines from its waveform's windows (VoiceLines' rule), the result, and the schema matching the rule's range.

func runSpeechDuckChecks() {
    duckWindowChecks()
    duckCurveChecks()
    duckRepeatChecks()
    duckEdgeChecks()
    duckShallowRampChecks()
    duckTargetChecks()
    duckPauseChecks()
    duckReportChecks()
}

private func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6, line: Int = #line) {
    check(abs(actual - expected) < tolerance, "\(message): got \(actual), expected \(expected)", line: line)
}

/// A 0 dB music clip on the timeline (volume 1, no curve).
private func duckBed(_ start: Double = 0, _ duration: Double = 12, volume: Double = 1) -> EditClip {
    var clip = audioClip(start, duration)
    clip.volume = volume
    return clip
}

/// Ducks `clip` under `lines` by `depth` and returns it with the result.
private func ducked(_ clip: EditClip, lines: [ClosedRange<Double>], depth: Double = -10) -> (clip: EditClip, result: SpeechDuckCurve.Result) {
    var copy = clip
    let result = SpeechDuckCurve.duck(&copy, under: SpeechDuck.windows(lines), depth: depth)
    return (copy, result)
}

/// The windows are these (from, holdFrom, holdTo, to), within float noise.
private func sameWindows(_ actual: [SpeechDuck.Window], _ expected: [[Double]], _ message: String, line: Int = #line) {
    let flat = actual.flatMap { [$0.from, $0.holdFrom, $0.holdTo, $0.to] }
    check(flat.count == expected.joined().count && zip(flat, expected.joined()).allSatisfy { abs($0 - $1) < 1e-9 },
          "\(message): got \(actual)", line: line)
}

private func duckWindowChecks() {
    let one = SpeechDuck.windows([2...4])
    sameWindows(one, [[1.6, 2, 4, 4.5]], "a line's window: 0.4 s before, 0.5 s after")
    near(one[0].fraction(at: 1.6), 0, "the dip starts at the window's start")
    near(one[0].fraction(at: 1.8), 0.5, "half way down in the middle of the attack")
    near(one[0].fraction(at: 3), 1, "full through the line")
    near(one[0].fraction(at: 4.25), 0.5, "half way back in the middle of the release")
    near(one[0].fraction(at: 4.5), 0, "back at the window's end")
    // 1.5 s between lines: the layer would be up for 0.6 s only, so it stays down.
    sameWindows(SpeechDuck.windows([5.5...7, 2...4]), [[1.6, 2, 7, 7.5]],
                "lines 1.5 s apart share one window (no pumping between them), in any order")
    checkEqual(SpeechDuck.windows([2...4, 6.5...8]).count, 2, "lines 2.5 s apart get a window each (up for 1.6 s between)")
    sameWindows(SpeechDuck.windows([2...6, 3...4]), [[1.6, 2, 6, 6.5]], "a line inside another adds nothing")
    checkEqual(SpeechDuck.windows([3...3]), [], "an empty line has no window")
    near(SpeechDuck.depthRange.lowerBound, -30, "the deepest dip is -30 dB")
    near(SpeechDuck.depthRange.upperBound, 0, "0 is no dip")
}

private func duckCurveChecks() {
    let (bed, result) = ducked(duckBed(), lines: [2...4])
    checkEqual(result, .ducked(windows: 1, reached: -10), "the bed dips under the line")
    for (time, expected) in [(1.0, 0.0), (1.6, 0), (1.8, -5), (2, -10), (3, -10), (4, -10), (4.25, -5), (4.5, 0), (9, 0)] {
        near(bed.volumeLineDecibels(atTimeline: time), expected, "flat bed ducked -10 under [2, 4], at \(time) s")
    }
    checkEqual(bed.volumeCurve.keys.count, 4, "four keys: down, full, end of the line, back")
    // Two lines far apart: two dips, back up between them.
    let (two, _) = ducked(duckBed(), lines: [2...3, 7...8])
    near(two.volumeLineDecibels(atTimeline: 5), 0, "between two dips the bed is back at its level")
    near(two.volumeLineDecibels(atTimeline: 7.5), -10, "the second line dips too")
    // A sloped line (a fade drawn as a curve): the dip follows the slope, 10 dB under it.
    var sloped = duckBed()
    sloped.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 1, value: 0), Keyframe(time: 5, value: -6)])
    let (slopedDuck, _) = ducked(sloped, lines: [2...4])
    near(slopedDuck.volumeLineDecibels(atTimeline: 3), -3 - 10, "a sloped line dips 10 dB under itself")
    near(slopedDuck.volumeLineDecibels(atTimeline: 6), -6, "after the window the slope's end level is untouched")
    // A crossfade bump above the edge line stays, lowered with the rest.
    var bumped = duckBed()
    bumped.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2.5, value: 0), Keyframe(time: 3, value: 3), Keyframe(time: 3.5, value: 0)])
    let (bumpDuck, _) = ducked(bumped, lines: [2...4])
    near(bumpDuck.volumeLineDecibels(atTimeline: 3), -7, "a +3 dB bump under the line is kept: -10 + 3")
    near(bumpDuck.volumeLineDecibels(atTimeline: 2.25), -10, "beside the bump the line is the plain dip")
    // Speed 2: the dip is drawn in timeline seconds whatever the source runs at.
    var fast = duckBed()
    fast.speed = 2
    let (fastDuck, _) = ducked(fast, lines: [2...4])
    near(fastDuck.volumeLineDecibels(atTimeline: 3), -10, "a 2x clip dips at the line's timeline time")
    near(fastDuck.volumeLineDecibels(atTimeline: 1.8), -5, "a 2x clip's attack is 0.4 timeline seconds")
    // The volume floor: a bed at -55 dB can only go 5 dB down; reported, never invented.
    let (floored, floorResult) = ducked(duckBed(volume: AudioGain.linear(fromDecibels: -55)), lines: [2...4])
    near(floored.volumeLineDecibels(atTimeline: 3), AudioGain.minimumDB, "the dip stops at the volume floor")
    if case .ducked(_, let reached?) = floorResult { near(reached, -5, "the result says the dip reached only -5 dB") }
    else { check(false, "a floored dip still reports how deep it got") }
}

private func duckRepeatChecks() {
    let (once, _) = ducked(duckBed(), lines: [2...4, 7...8])
    let (twice, _) = ducked(once, lines: [2...4, 7...8])
    check(SpeechDuckPlanner.sameLine(once.volumeCurve, twice.volumeCurve, tolerance: 1e-6),
          "ducking again with the same depth changes nothing (never stacks)")
    let (shallower, _) = ducked(once, lines: [2...4, 7...8], depth: -6)
    near(shallower.volumeLineDecibels(atTimeline: 3), -6, "ducking again at -6 sets the dip to -6, not -16")
    let (deeper, _) = ducked(once, lines: [2...4, 7...8], depth: -14)
    near(deeper.volumeLineDecibels(atTimeline: 7.5), -14, "ducking again at -14 sets it to -14")
    let (lifted, _) = ducked(once, lines: [2...4, 7...8], depth: 0)
    for time in stride(from: 0.0, through: 12, by: 0.25) {
        near(lifted.volumeLineDecibels(atTimeline: time), 0, "duck_others_db 0 takes the dip out, at \(time) s")
    }
    // A bump drawn after the duck (set_transition sound) survives ducking again.
    var bumpedLater = once
    var keys = bumpedLater.volumeCurve.keys
    keys.append(Keyframe(time: 3, value: -7))
    bumpedLater.volumeCurve = KeyframeTrack(keys: keys)
    let (redone, _) = ducked(bumpedLater, lines: [2...4, 7...8])
    near(redone.volumeLineDecibels(atTimeline: 3), -7, "a bump raised over the dip after ducking stays when ducking again")
    // Planner: the same call twice leaves the state equal, so the second call commits nothing.
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(1, 6)]), EditLane(clips: [duckBed()])]
    let targets = SpeechDuckPlanner.targets(in: state, voice: .audio(0), speech: [state.audioTracks[0].clips[0].id], only: nil)
    let windows = SpeechDuck.windows([2...4])
    var first = state
    let firstRun = SpeechDuckPlanner.run(windows, depth: -10, targets: targets, in: &first)
    var second = first
    let secondRun = SpeechDuckPlanner.run(windows, depth: -10, targets: targets, in: &second)
    check(firstRun.allSatisfy(\.changed) && !secondRun.contains(where: \.changed), "the first call changes the bed, the second nothing")
    check(second == first, "calling twice leaves the same state")
}

private func duckEdgeChecks() {
    // A line right at the bed's start: its window starts before the clip and takes its level from the other end.
    let (early, _) = ducked(duckBed(2, 8), lines: [2.1...3])
    near(early.volumeLineDecibels(atTimeline: 2), -7.5, "at the clip's start the window is three quarters down")
    near(early.volumeLineDecibels(atTimeline: 2.5), -10, "full under the line")
    let (earlyAgain, _) = ducked(early, lines: [2.1...3])
    check(SpeechDuckPlanner.sameLine(early.volumeCurve, earlyAgain.volumeCurve, tolerance: 1e-6),
          "a window crossing the clip's start does not stack when ducking again")
    // A key the clip keeps in its trimmed-off head, right next to the clip's start: the dip's key at the start wins.
    var trimmed = duckBed(2, 8)
    trimmed.sourceStart = 5
    trimmed.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 4.9998, value: 0)])
    let (trimmedDuck, _) = ducked(trimmed, lines: [2.1...3])
    near(trimmedDuck.volumeLineDecibels(atTimeline: 2), -7.5, "a kept key 0.2 ms from the clip's start takes the dip's value there",
         tolerance: 0.01)
    checkEqual(trimmedDuck.volumeCurve.keys.count, 4, "the kept key and the dip's start key are one key, not two")
    // A window crossing the clip's end.
    let (late, _) = ducked(duckBed(0, 3.2), lines: [2...4])
    near(late.volumeLineDecibels(atTimeline: 3), -10, "a bed ending under a line dips to its end")
    // A sound wholly inside a line is left alone.
    let effect = duckBed(2.5, 0.5)
    let (inside, insideResult) = ducked(effect, lines: [2...4])
    checkEqual(insideResult, .insideLine, "an effect lying on the line is not ducked")
    check(inside == effect, "an effect lying on the line keeps its line")
    let (_, away) = ducked(duckBed(6, 2), lines: [2...4])
    checkEqual(away, .untouched, "a clip no window reaches is untouched")
}

/// A clip only the shallow part of a ramp reaches (less than half way down; CXR2 R9, 2026-11-19): the dip is read from the
/// part the clip covers, so calling again never stacks and 0 takes it out. Before the fix a bed ending a quarter of the way
/// down the attack went -2.5 / -5 / -5 dB for -10 / -10 / 0. The line [2, 2.5] dips over [1.6, 3].
private func duckShallowRampChecks() {
    for (name, bed, edge, fraction) in [("ending in the attack", duckBed(0, 1.7), 1.7, 0.25),
                                         ("ending 2 ms into the attack", duckBed(0, 1.602), 1.602, 0.005),
                                         ("starting in the release", duckBed(2.8, 4), 2.8, 0.4)] {
        let (once, result) = ducked(bed, lines: [2...2.5])
        checkEqual(result, .ducked(windows: 1, reached: nil), "a bed \(name) dips (only a ramp reaches it)")
        near(once.volumeLineDecibels(atTimeline: edge), -10 * fraction, "a bed \(name) is \(fraction) of the way down at its edge")
        let (twice, _) = ducked(once, lines: [2...2.5])
        check(SpeechDuckPlanner.sameLine(once.volumeCurve, twice.volumeCurve, tolerance: 1e-6),
              "a bed \(name): ducking again with the same depth changes nothing (got \(twice.volumeLineDecibels(atTimeline: edge)) dB)")
        let (deeper, _) = ducked(twice, lines: [2...2.5], depth: -20)
        near(deeper.volumeLineDecibels(atTimeline: edge), -20 * fraction, "a bed \(name): -20 after -10 sets the dip, never stacks")
        let (lifted, _) = ducked(deeper, lines: [2...2.5], depth: 0)
        for time in [edge, (edge + (edge < 2 ? 1.6 : 3)) / 2] + Array(stride(from: bed.timelineStart, through: bed.timelineEnd, by: 0.05)) {
            near(lifted.volumeLineDecibels(atTimeline: time), 0, "a bed \(name): duck_others_db 0 takes the dip out, at \(time) s")
        }
    }
    // A window reaching less than a millisecond in: its corner keys would merge, so the clip is left alone (never nudged by
    // a few thousandths of a dB on every call).
    let sliver = duckBed(0, 1.6003)
    let (touched, sliverResult) = ducked(sliver, lines: [2...2.5])
    checkEqual(sliverResult, .untouched, "a window reaching 0.3 ms into a clip leaves it alone")
    check(touched == sliver, "a window reaching 0.3 ms into a clip draws nothing")
}

private func duckTargetChecks() {
    var state = TimelineState()
    var picture = videoClip(0, 10)
    picture.volume = 1
    let voice = audioClip(1, 8)
    var detached = audioClip(1, 8)
    detached.isMuted = false
    var muted = duckBed(0, 10)
    muted.isMuted = true
    var hidden = duckBed(0, 10)
    hidden.isHidden = true
    let silent = duckBed(0, 10, volume: 0)
    let effect = duckBed(2.5, 0.5)
    state.mainClips = [picture]
    state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [duckBed(0, 12)]), EditLane(clips: [effect, muted]),
                         EditLane(clips: [duckBed(0, 12)], isHidden: true), EditLane(clips: [hidden, silent]),
                         EditLane(clips: [detached])]
    let all = SpeechDuckPlanner.targets(in: state, voice: .audio(0), speech: [voice.id, detached.id], only: nil)
    checkEqual(all.map(\.track), [.main, .audio(1), .audio(2)],
               "V1's own sound, the bed and the effect dip; not the voice, its separated sound, muted, hidden or silent clips")
    let only = SpeechDuckPlanner.targets(in: state, voice: .audio(0), speech: [voice.id], only: [.audio(1)])
    checkEqual(only.map(\.track), [.audio(1)], "duck_tracks keeps only the named tracks")
    var next = state
    let outcomes = SpeechDuckPlanner.run(SpeechDuck.windows([2...4]), depth: -10, targets: all, in: &next)
    checkEqual(outcomes.map(\.result), [.ducked(windows: 1, reached: -10), .ducked(windows: 1, reached: -10), .insideLine],
               "the picture's sound and the bed dip, the effect is listed as inside a line")
    check(next.clip(with: voice.id) == voice && next.clip(with: effect.id) == effect, "the voice and the effect keep their lines")
}

private func duckPauseChecks() {
    // 50 ms windows: 0.5 s quiet, 1 s speech, 0.3 s breath, 1 s speech, 1 s pause, 1 s speech.
    var windows: [AIAudioLevels.Window] = []
    var time = 0.0
    for (seconds, decibels) in [(0.5, -90.0), (1, -20), (0.3, -90), (1, -20), (1, -90), (1, -22)] {
        for _ in 0..<Int((seconds / 0.05).rounded()) {
            let power = pow(10, decibels / 10)
            windows.append(AIAudioLevels.Window(start: time, end: time + 0.05, meanSquare: power, peak: power.squareRoot()))
            time += 0.05
        }
    }
    let clip = audioClip(10, 4.8)
    let lines = SpeechDuckPlanner.lines(fromPauses: windows, of: clip, windowSeconds: 0.05)
    checkEqual(lines.count, 2, "a 0.3 s breath stays inside a line, a 1 s pause ends it")
    if lines.count == 2 {
        near(lines[0].lowerBound, 10.5, "the first line starts with the speech, on the timeline", tolerance: 1e-9)
        near(lines[0].upperBound, 12.8, "the first line runs through the breath", tolerance: 1e-9)
        near(lines[1].lowerBound, 13.8, "the second line starts after the pause", tolerance: 1e-9)
    }
    checkEqual(SpeechDuckPlanner.lines(fromPauses: [], of: clip, windowSeconds: 0.05), [], "no windows, no lines")
}

private func duckReportChecks() {
    var state = TimelineState()
    let voice = audioClip(1, 8)
    let bed = duckBed(0, 12)
    let low = duckBed(0, 12, volume: AudioGain.linear(fromDecibels: -55))
    let effect = duckBed(2.5, 0.5)
    state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [bed]), EditLane(clips: [low]), EditLane(clips: [effect])]
    let windows = SpeechDuck.windows([2...4])
    var next = state
    let targets = SpeechDuckPlanner.targets(in: state, voice: .audio(0), speech: [voice.id], only: nil)
    let outcomes = SpeechDuckPlanner.run(windows, depth: -10, targets: targets, in: &next)
    var speech = SpeechDuckPlanner.Speech()
    speech.lines = [2...4]
    speech.clips = [voice.id]
    speech.fromPauses = [voice.id]
    let ids = AIShortIDs(state: next)
    let json = SpeechDuckReport.json(voice: .audio(0), depth: -10, speech: speech, windows: windows, outcomes: outcomes, ids: ids)
    checkEqual(json["track"], "A1", "the result names the track that speaks")
    checkEqual(json["duck_db"], -10, "the result gives the depth")
    checkEqual(json["windows"], [[1.6, 4.5]], "the result lists the dip windows")
    checkEqual(json["ducked"]?.arrayValue?.count, 2, "two clips dipped")
    checkEqual(json["inside_lines"], [["id": .string(ids.short(effect.id)), "track": "A4"]], "the effect is listed as inside a line")
    checkEqual(json["adjustments"]?.arrayValue?.first?["applied_db"], -5, "the floored bed reports the dip it reached")
    checkEqual(json["lines_from"]?["pauses"], [.string(ids.short(voice.id))], "the lines came from the narration's pauses")
    check(json["next_step"]?.stringValue?.contains("never stacks") == true, "the next step says calling again never stacks")
    // The schema's range is the rule's range, and the guide has the ducking section.
    let schema = MCPToolName.setTrack.definition.inputSchema["properties"]?["duck_others_db"]
    checkEqual(schema?["minimum"], .number(SpeechDuck.depthRange.lowerBound), "duck_others_db's minimum is the rule's")
    checkEqual(schema?["maximum"], .number(SpeechDuck.depthRange.upperBound), "duck_others_db's maximum is the rule's")
    let guide = MCPGuideWrittenTopics.topic(for: .setTrack)
    check(guide?.sections.contains { $0.name == "ducking" && $0.text.contains("duck_tracks") } == true,
          "set_track's guide topic explains ducking and duck_tracks")
}

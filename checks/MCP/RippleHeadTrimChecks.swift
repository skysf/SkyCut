import Foundation
import SrtFlowMCPKit

// A J cut's sound that an AI edit pushes before 0:00 (ripple-deleting or shortening the first V1 clip, cut_to_beat) used to be
// clamped at 0, so it ran late by its lead-in. Now it loses its head instead (`EditClip.moveForLinkage`, linkage rule 13) and
// the reply lists it in linkage.trimmed_heads (`LinkageHeadTrims`, `AILinkageReport`). G15 follow-up, 2026-11-17.
// Case: docs/bugfixes/2026-11-17-ai-ripple-clamps-j-cut-lead-at-zero.md.

func runRippleHeadTrimChecks() {
    rippleDeleteChecks()
    editClipRippleChecks()
    beatCutHeadChecks()
    headTrimReportChecks()
}

/// face 0–4 and ship 4–9 on V1 (ship from 10 s in the file); ship's sound separated to A1 and leading by 0.5 s (a J cut:
/// 3.5–9 from 9.5 s, the same timing as ship) with a 0.3 s fade-in.
private func jCutProject() -> (state: TimelineState, face: UUID, ship: UUID, sound: UUID) {
    var state = TimelineState()
    let face = videoClip(0, 4)
    let ship = videoClip(4, 5, sourceStart: 10)
    state.mainClips = [face, ship]
    let sound = ClipSoundSeparation.separate(ship.id, in: &state) ?? UUID()
    state.update(sound) {
        $0.timelineStart = 3.5
        $0.sourceStart = 9.5
        $0.sourceDuration = 5.5
        $0.fadeInDuration = 0.3
    }
    return (state, face.id, ship.id, sound)
}

private func checkSeconds(_ actual: Double?, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) < 1e-6 else {
        failures += 1
        print("FAIL [RippleHeadTrim:\(line)] \(message): got \(actual.map { String($0) } ?? "nil"), expected \(expected)")
        return
    }
}

/// Sound and picture show the same moment of the file at the same time.
private func inSync(_ sound: UUID, _ picture: UUID, _ state: TimelineState, at source: Double) -> Bool {
    guard let heard = state.clip(with: sound), let seen = state.clip(with: picture) else { return false }
    return abs(heard.timelineTime(atSource: source) - seen.timelineTime(atSource: source)) < 1e-6
}

private func rippleDeleteChecks() {
    let (start, face, ship, sound) = jCutProject()
    check(inSync(sound, ship, start, at: 12), "set-up: the J-cut sound is in sync with ship")

    // delete_items ids=[face] ripple=true, linkage on: ship moves to 0 and its sound would start at -0.5.
    var next = start
    AITimelineEdits.delete(.init(clips: [face]), ripple: true, linkage: true, in: &next)
    let report = TimelineLinkage.follow(from: start, to: &next, deletesContent: true)
    checkEqual(mainStarts(next), [0], "ripple-delete the first clip: ship moves to 0")
    let moved = next.clip(with: sound)
    checkSeconds(moved?.timelineStart, 0, "ripple-delete the first clip: the J-cut sound starts at 0")
    checkSeconds(moved?.sourceStart, 10, "ripple-delete the first clip: …its 0.5 s before 0:00 is trimmed, not shifted late")
    checkSeconds(moved.map { $0.sourceStart + $0.sourceDuration }, 15, "ripple-delete the first clip: …and it still ends with ship")
    checkSeconds(moved?.fadeInDuration, 0, "ripple-delete the first clip: the fade-in that was before 0:00 went with it")
    check(inSync(sound, ship, next, at: 12), "ripple-delete the first clip: sound and picture stay in sync")
    checkSeconds(report.trimmedHeads[sound], 0.5, "ripple-delete the first clip: the report says 0.5 s was trimmed")

    // Control: a ripple that leaves the lead after 0:00 moves it whole and reports no trim.
    var later = start
    let extra = videoClip(0, 2, sourceStart: 30)
    later.mainClips.insert(extra, at: 0)
    later.mainClips[1].timelineStart = 2
    later.mainClips[2].timelineStart = 6
    later.update(sound) { $0.timelineStart = 5.5 }
    var shifted = later
    AITimelineEdits.delete(.init(clips: [face]), ripple: true, linkage: true, in: &shifted)
    let quiet = TimelineLinkage.follow(from: later, to: &shifted, deletesContent: true)
    checkSeconds(shifted.clip(with: sound)?.timelineStart, 1.5, "a lead that stays after 0:00 moves whole")
    checkSeconds(shifted.clip(with: sound)?.sourceStart, 9.5, "…keeping its in point")
    check(quiet.trimmedHeads.isEmpty, "…and nothing is reported as trimmed")
}

private func editClipRippleChecks() {
    // edit_clip face source_out=0.4 ripple=true: ship moves back 3.6 s to 0.4, its sound would start at -0.1.
    let (start, face, ship, sound) = jCutProject()
    var change = AIClipChange()
    change.sourceOut = 0.4
    change.ripple = true
    guard var next = try? AIClipEdit.apply(change, to: face, linkage: true, stillDuration: 5, in: start) else {
        return check(false, "edit_clip ripple on the first clip works")
    }
    let report = TimelineLinkage.follow(from: start, to: &next, deletesContent: false)
    checkSeconds(next.clip(with: ship)?.timelineStart, 0.4, "edit_clip ripple: ship closes up to 0.4")
    checkSeconds(next.clip(with: sound)?.timelineStart, 0, "edit_clip ripple: the J-cut sound starts at 0")
    checkSeconds(next.clip(with: sound)?.sourceStart, 9.6, "edit_clip ripple: …with 0.1 s trimmed off its head")
    check(inSync(sound, ship, next, at: 12), "edit_clip ripple: sound and picture stay in sync")
    checkSeconds(report.trimmedHeads[sound], 0.1, "edit_clip ripple: the report says 0.1 s was trimmed")
}

private func beatCutHeadChecks() {
    // cut_to_beat with one beat per clip, beats every 0.4 s: a (0–2) becomes 0–0.4, b (2–4, J-cut sound from 1.5) moves to
    // 0.4, so its sound would start at -0.1.
    var state = TimelineState()
    let a = videoClip(0, 2, sourceStart: 40)
    let b = videoClip(2, 2, sourceStart: 20)
    state.mainClips = [a, b]
    let sound = ClipSoundSeparation.separate(b.id, in: &state) ?? UUID()
    state.update(sound) {
        $0.timelineStart = 1.5
        $0.sourceStart = 19.5
        $0.sourceDuration = 2.5
    }
    let beats = (0..<20).map { Double($0) * 0.4 }
    let placed = AIBeatCuts.layout([a, b].map {
        AIBeatCuts.Clip(id: $0.id, start: $0.timelineStart, duration: $0.timelineDuration, maxDuration: 10)
    }, beats: beats, beatsPerClip: 1)
    var next = state
    AIBeatCuts.apply(placed, in: &next)
    let report = TimelineLinkage.follow(from: state, to: &next, deletesContent: false)
    checkSeconds(next.clip(with: b.id)?.timelineStart, 0.4, "cut_to_beat: b moves to the beat at 0.4")
    checkSeconds(next.clip(with: sound)?.timelineStart, 0, "cut_to_beat: b's J-cut sound starts at 0")
    checkSeconds(next.clip(with: sound)?.sourceStart, 19.6, "cut_to_beat: …with 0.1 s trimmed off its head")
    check(inSync(sound, b.id, next, at: 20.2), "cut_to_beat: sound and picture stay in sync")
    checkSeconds(next.clip(with: sound)?.timelineEnd, 0.8, "cut_to_beat: the sound still ends where b ends")
    checkSeconds(report.trimmedHeads[sound], 0.1, "cut_to_beat: the report says 0.1 s was trimmed")
}

private func headTrimReportChecks() {
    let sound = UUID()
    let ids = AIShortIDs([sound])
    let report = TimelineLinkage.Report(trimmedHeads: [sound: 0.5])
    check(!report.isEmpty, "a trimmed head alone is worth reporting")
    let json = AILinkageReport.json(report, ids: ids)
    let entry = json?["trimmed_heads"]?.arrayValue?.first
    checkEqual(entry?["id"]?.stringValue, ids.short(sound), "trimmed_heads lists the clip's short id")
    checkEqual(entry?["seconds"]?.doubleValue, 0.5, "…and how many seconds it lost")
    check(json?["note"]?.stringValue?.contains("trimmed_heads") == true, "the note says what trimmed_heads means")
    check(AILinkageReport.json(TimelineLinkage.Report(moved: 1), ids: ids)?["trimmed_heads"] == nil, "no list when nothing was trimmed")
}

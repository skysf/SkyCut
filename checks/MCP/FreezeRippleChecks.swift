import CoreGraphics
import Foundation
import SrtFlowCore

// A freeze on a clip whose sound is separated (J / L cut), then the follow-ups the AI is told to make: delete the hold with
// ripple, or delete the tail after it (P5 walkthrough to-do 1, 2026-11-17).
// Before the fix the tail kept the clip's link group: rippling the hold moved the whole clip (and its sound) 2 s back onto the
// clip before it on V1, and deleting the tail deleted the clip and its sound too. Fixes: the tail keeps no link group
// (`insertFreeze`), and a ripple only brings a link group along when none of its V1 pictures stays (`RippleLinkPartners`).
// Case: docs/bugfixes/2026-11-17-freeze-tail-ripple-drags-its-clip.md.

func runFreezeRippleChecks() {
    freezeThenDeleteChecks()
    oldTailRippleChecks()
}

private let shipFile = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/ship.mp4")
private let stillFile = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/ship-still.mp4")
private let frameFile = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/ship-freeze.png")

/// The walkthrough's project: face 0–4 and ship 4–9 on V1 (24 fps), both added with sound=separate; ship's sound moved to A2
/// and started one second early (3–9, J cut). Returns the state and the ids of ship and its sound.
private func walkthroughProject() -> (state: TimelineState, ship: UUID, sound: UUID) {
    var face = videoClip(0, 4)
    var ship = videoClip(4, 5, sourceStart: 1)
    ship.sourceURL = shipFile
    face.info?.frameRate = 24
    ship.info?.frameRate = 24
    var state = TimelineState()
    state.mainClips = [face, ship]
    ClipSoundSeparation.separate(face.id, in: &state)
    let soundID = ClipSoundSeparation.separate(ship.id, in: &state) ?? UUID()
    guard var sound = state.clip(with: soundID) else { return (state, ship.id, soundID) }
    state.remove(soundID)
    sound.timelineStart = 3
    sound.sourceStart = 0
    sound.sourceDuration = 6
    state.audioTracks.append(EditLane(clips: [sound]))
    return (state, ship.id, soundID)
}

/// `perform`'s ending with the magnet off: linkage follows the edit.
private func committed(_ next: TimelineState, after before: TimelineState, deletes: Bool) -> TimelineState {
    var state = next
    TimelineLinkage.follow(from: before, to: &state, deletesContent: deletes)
    return state
}

private func noOverlapOnV1(_ state: TimelineState) -> Bool {
    state.mainClips.allSatisfy { AITimelineEdits.conflict(for: $0.id, in: state) == nil }
}

private func freezeThenDeleteChecks() {
    let (start, shipID, soundID) = walkthroughProject()
    guard let ship = start.clip(with: shipID) else { return check(false, "the walkthrough project has its ship clip") }
    // freeze_frame time=8.958 → a 2 s hold and a 0.042 s tail (one frame at 24 fps is 0.0417 s, so it stays).
    let hold = ship.makeFreezeClip(image: frameFile, still: stillFile, info: ship.info, at: 8.958, duration: 2,
                                   canvas: CGSize(width: 1920, height: 1080))
    var next = start
    next.insertFreeze(hold, splitting: shipID, at: 8.958)
    let frozen = committed(next, after: start, deletes: false)
    guard let tail = frozen.mainClips.last, tail.id != hold.id, tail.sourceURL == shipFile else {
        return check(false, "the freeze leaves a tail of the ship after the hold")
    }
    checkEqual(mainStarts(frozen), [0, 4, 8.958, 10.958], "freeze: the hold at 8.958, the tail after it")
    check(tail.linkGroup == nil, "freeze: the tail is not linked (its sound stays under the hold)")
    checkEqual(frozen.linkedClipIDs(of: tail.id), [tail.id], "freeze: the tail has no link partners")
    checkEqual(frozen.linkedClipIDs(of: shipID), [shipID, soundID], "freeze: ship and its sound are still a pair")

    // delete_items ids=[hold] ripple=true (linkage on): only the tail and later V1 clips move back.
    var rippled = frozen
    AITimelineEdits.delete(.init(clips: [hold.id]), ripple: true, linkage: true, in: &rippled)
    rippled = committed(rippled, after: frozen, deletes: true)
    checkEqual(mainStarts(rippled), [0, 4, 8.958], "ripple-delete the hold: ship stays at 4, the tail closes up to 8.958")
    checkEqual(rippled.clip(with: soundID)?.timelineStart, 3, "ripple-delete the hold: ship's sound stays at 3")
    check(noOverlapOnV1(rippled), "ripple-delete the hold: nothing overlaps on V1")

    // delete_items ids=[tail] (what the freeze_frame reply suggests): only the tail goes.
    var trimmed = frozen
    AITimelineEdits.delete(.init(clips: [tail.id]), ripple: false, linkage: true, in: &trimmed)
    trimmed = committed(trimmed, after: frozen, deletes: true)
    check(trimmed.clip(with: shipID) != nil, "delete the tail: the ship clip stays")
    check(trimmed.clip(with: soundID) != nil, "delete the tail: ship's sound stays")
    checkEqual(mainStarts(trimmed), [0, 4, 8.958], "delete the tail: the clip ends on the hold")
}

/// A tail saved before the fix still shares the clip's link group (and so does a split made with linkage off): a ripple must
/// not drag the clip before the ripple point, nor the sound it shares with it.
private func oldTailRippleChecks() {
    let (start, shipID, soundID) = walkthroughProject()
    guard let ship = start.clip(with: shipID), let group = ship.linkGroup else {
        return check(false, "the walkthrough project has a linked ship clip")
    }
    var left = ship
    left.sourceDuration = 4.958
    var hold = videoClip(8.958, 2)
    hold.sourceURL = stillFile
    var tail = videoClip(10.958, 0.042, sourceStart: 5.958)
    tail.sourceURL = shipFile
    tail.isMuted = true
    tail.linkGroup = group
    var state = start
    state.mainClips = [start.mainClips[0], left, hold, tail]

    var rippled = state
    AITimelineEdits.delete(.init(clips: [hold.id]), ripple: true, linkage: true, in: &rippled)
    rippled = committed(rippled, after: state, deletes: true)
    checkEqual(mainStarts(rippled), [0, 4, 8.958], "old linked tail: ripple moves only the tail")
    checkEqual(rippled.clip(with: soundID)?.timelineStart, 3, "old linked tail: the shared sound stays with the clip that stays")
    check(noOverlapOnV1(rippled), "old linked tail: nothing overlaps on V1")

    // A group none of whose V1 pictures stays comes along as before: delete A with ripple, B and its sound move back 4 s.
    var pair = TimelineState()
    let a = videoClip(0, 4)
    let b = videoClip(4, 5, sourceStart: 10)
    pair.mainClips = [a, b]
    let bSound = ClipSoundSeparation.separate(b.id, in: &pair) ?? UUID()
    AITimelineEdits.delete(.init(clips: [a.id]), ripple: true, linkage: true, in: &pair)
    checkEqual(mainStarts(pair), [0], "ripple-delete the first clip: the next one moves to 0")
    checkEqual(pair.clip(with: bSound)?.timelineStart, 0, "ripple-delete the first clip: its separated sound comes along")
}

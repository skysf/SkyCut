import CoreGraphics
import Foundation
import SrtFlowCore

// The right piece after a freeze hold keeps no link group (2026-11-17). It resumes after the hold while the clip's separated
// sound (or a recording's mic) stays where it was, so it is no longer their pair. While it kept the group, deleting it (what
// freeze_frame's tail_id note suggests) also deleted the clip and its sound, and a ripple that moved it dragged the clip back
// onto its neighbour on V1. Case: docs/bugfixes/2026-11-17-freeze-tail-ripple-drags-its-clip.md.
func checkFreezeLinks() {
    let group = UUID()
    var picture = videoClip(start: 0, duration: 10)
    picture.linkGroup = group
    picture.isMuted = true
    let sound = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 10, timelineStart: 0, linkGroup: group,
                         audioAssetDuration: 10)
    var linked = TimelineState(mainClips: [picture])
    linked.audioTracks = [EditLane(clips: [sound])]

    var state = linked
    state.insertFreeze(freeze(of: picture, at: 6), splitting: picture.id, at: 6)
    check(state.mainClips.count == 3, "freeze inside a linked clip: left, hold, right")
    if state.mainClips.count == 3 {
        let right = state.mainClips[2]
        checkClose(right.timelineStart, 8, "the right piece resumes after the hold")
        check(right.linkGroup == nil, "the right piece keeps no link group (its sound stayed under the hold)")
        check(state.linkedClipIDs(of: right.id) == [right.id], "the right piece has no link partners")
        check(state.mainClips[1].linkGroup == nil, "the hold is not linked either")
    }
    check(state.clip(with: picture.id)?.linkGroup == group, "the left piece keeps its group")
    check(state.linkedClipIDs(of: picture.id) == [picture.id, sound.id], "the left piece and its sound are still a pair")
    check(state.audioTracks == linked.audioTracks, "the freeze does not touch the separated sound")

    // At the clip's first frame nothing is split: the clip moves on whole and keeps its sound (linkage then moves it along).
    var prefix = linked
    prefix.insertFreeze(freeze(of: picture, at: 0), splitting: picture.id, at: 0)
    check(prefix.clip(with: picture.id)?.linkGroup == group, "a freeze at the first frame keeps the clip's group")
    check(prefix.linkedClipIDs(of: picture.id) == [picture.id, sound.id], "a freeze at the first frame keeps the pair")
}

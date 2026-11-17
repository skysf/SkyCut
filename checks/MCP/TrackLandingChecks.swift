import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// Where add_clips puts a clip that names a track (AITrackLanding, AITimelineEdits.place; docs/architecture/ai-control-mcp.md
// section 4 item 2): a taken track opens another new track and never sends the clip to a track that already had content (MCP-2);
// A-numbers past the last audio track are created in one call, in number order, without gaps (MCP-4); every clip that is not
// where it asked to be gets a `track` adjustment. The same calls on real App objects: checks/ParameterLimits/AddClipsChecks.swift.

func runTrackLandingChecks() {
    trackRequestChecks()
    crowdedNewAudioChecks()
    namedTrackChecks()
    numberedTrackChecks()
    liftedVideoChecks()
}

private func audioPlan(_ clip: EditClip, _ target: TrackDropTarget?, number: Int? = nil) -> AITimelineEdits.PlannedClip {
    AITimelineEdits.PlannedClip(clip: clip, isAudio: true, target: target, start: clip.timelineStart, audioNumber: number)
}

/// A1: a voice line 0–3 s; A2: music 10–20 s. Both have room between 3 and 10 s.
private func voiceAndMusic() -> TimelineState {
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(0, 3)]), EditLane(clips: [audioClip(10, 10)])]
    return state
}

private func trackRequestChecks() {
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(0, 2)])]
    let named = try? AITrackLanding.request("A3", in: state)
    checkEqual(named?.audioNumber, 3, "A3 with only A1 is a track this call creates (MCP-4: it used to fail the whole call)")
    checkEqual(named?.target, .newAudioBottom, "…an audio track")
    checkEqual(named?.name, "A3", "…named as written")
    checkEqual((try? AITrackLanding.request("a1", in: state))?.target, .audio(0), "an existing audio track is itself")
    checkEqual((try? AITrackLanding.request("A1", in: state))?.audioNumber, nil, "…not a new one")
    checkEqual((try? AITrackLanding.request("new_audio", in: state))?.name, "new_audio", "new_audio keeps its name")
    checkEqual((try? AITrackLanding.request("new-video", in: state))?.name, "new_video", "new-video is new_video")
    checkEqual((try? AITrackLanding.request("main", in: state))?.name, "V1", "main is V1")
    checkThrows("V3 with no upper tracks still fails (video tracks are not created by number)") { _ = try AITrackLanding.request("V3", in: state) }
    checkThrows("A0 is not a track") { _ = try AITrackLanding.request("A0", in: state) }
}

/// MCP-2: 13 new_audio effects that overlap each other. Before the fix the ones that did not fit on the call's new track fell back
/// to the first free track: A1 (voice) and A2 (music).
private func crowdedNewAudioChecks() {
    var state = voiceAndMusic()
    let old = Set(state.audioTracks.flatMap(\.clips).map(\.id))
    let clips = (0..<13).map { audioClip(3.5 + Double($0) * 0.4, 1.2) }
    let notes = AITimelineEdits.place(clips.map { audioPlan($0, .newAudioBottom) }, insert: false, linkage: false, in: &state)
    let onOld = state.audioTracks.prefix(2).flatMap(\.clips).filter { !old.contains($0.id) }
    checkEqual(onOld.count, 0, "MCP-2: no new_audio clip lands on A1 (voice) or A2 (music)")
    let home = state.audioTracks.indices.contains(2) ? state.audioTracks[2].id : nil
    let homeIDs = Set(state.audioTracks.indices.contains(2) ? state.audioTracks[2].clips.map(\.id) : [])
    let spilled = clips.filter { !homeIDs.contains($0.id) }
    check(!spilled.isEmpty, "some clips did not fit on the call's new track")
    check(spilled.allSatisfy { clip in
        guard let note = notes[clip.id], case .busy = note.reason else { return false }
        return note.wanted == home.map { .lane($0) }
    }, "MCP-2: every clip that did not fit on the call's new track is noted (busy there)")
    check(clips.allSatisfy { clip in homeIDs.contains(clip.id) == (notes[clip.id] == nil) }, "the clips on the new track carry no note")
    check(state.audioTracks.allSatisfy { lane in
        lane.clips.indices.dropFirst().allSatisfy { lane.clips[$0].timelineStart >= lane.clips[$0 - 1].timelineEnd - 0.001 }
    }, "no two clips overlap on any track")
}

/// A named track taken at that time: a new track, not the first free one; a hidden one too. With room: where asked.
private func namedTrackChecks() {
    var state = voiceAndMusic()
    let music = state.audioTracks[1].clips[0].id
    let taken = audioClip(12, 0.5), free = audioClip(5, 0.5), afterTaken = audioClip(14, 0.5)
    let notes = AITimelineEdits.place([audioPlan(taken, .audio(1)), audioPlan(free, .audio(1)), audioPlan(afterTaken, .audio(1))],
                                      insert: false, linkage: false, in: &state)
    checkEqual(state.location(of: taken.id)?.track, .audio(2), "a clip on a taken spot of A2 opens A3 (not A1, which is free there)")
    checkEqual(state.location(of: afterTaken.id)?.track, .audio(2), "the next one that does not fit on A2 shares that new track")
    checkEqual(state.location(of: free.id)?.track, .audio(1), "a clip with room on A2 lands on A2")
    checkEqual(notes[taken.id], AITrackLanding.Note(wanted: .lane(state.audioTracks[1].id), reason: .busy(music)), "the note names the clip in the way")
    let ids = AIShortIDs(state: state)
    let request = AITrackLanding.Request(target: .audio(1), audioNumber: nil, name: "A2")
    let entry = AITrackLanding.adjustment(requested: request, note: notes[taken.id], slot: .audio(2), in: state, ids: ids)
    checkEqual(entry?["reason"]?.stringValue, "track_busy", "the reply says why")
    checkEqual(entry?["applied"]?.stringValue, "A3", "…and where it went")
    checkEqual(entry?["overlaps"]?.stringValue, ids.short(music), "…and what was in the way")
    check(AITrackLanding.adjustment(requested: request, note: nil, slot: .audio(1), in: state, ids: ids) == nil, "no adjustment where it asked")

    var hidden = voiceAndMusic()
    hidden.audioTracks[0].isHidden = true
    let quiet = audioClip(5, 0.5)
    let hiddenNotes = AITimelineEdits.place([audioPlan(quiet, .audio(0))], insert: false, linkage: false, in: &hidden)
    checkEqual(hidden.location(of: quiet.id)?.track, .audio(2), "a hidden named track: a new track")
    checkEqual(hiddenNotes[quiet.id]?.reason, .hidden, "…noted as hidden")
}

/// MCP-4: A1–A7 named in one call on a project with no audio tracks, in any order: created in number order, each clip on its own.
private func numberedTrackChecks() {
    var state = TimelineState()
    let order = [3, 1, 7, 2, 5, 4, 6]
    let clips = order.map { audioClip(Double($0), 0.5) }
    let notes = AITimelineEdits.place(zip(clips, order).map { audioPlan($0, .newAudioBottom, number: $1) }, insert: false, linkage: false, in: &state)
    checkEqual(state.audioTracks.count, 7, "MCP-4: seven tracks from one call")
    check(zip(clips, order).allSatisfy { state.location(of: $0.id)?.track == .audio($1 - 1) }, "MCP-4: every clip is on the track it named")
    check(notes.isEmpty, "…with nothing to note")

    var gap = TimelineState()
    let lone = audioClip(0, 1)
    _ = AITimelineEdits.place([audioPlan(lone, .newAudioBottom, number: 5)], insert: false, linkage: false, in: &gap)
    checkEqual(gap.location(of: lone.id)?.track, .audio(0), "A5 with no audio tracks is A1 (numbered without gaps)")
    let request = AITrackLanding.Request(target: .newAudioBottom, audioNumber: 5, name: "A5")
    let entry = AITrackLanding.adjustment(requested: request, note: nil, slot: .audio(0), in: gap, ids: AIShortIDs(state: gap))
    checkEqual(entry?["reason"]?.stringValue, "tracks_numbered_without_gaps", "…and the reply says why")

    // new_audio next to numbered tracks: its own track, after them; a clip that names no track still takes the first free one.
    var mixed = voiceAndMusic()
    let fresh = audioClip(5, 1), numbered = audioClip(5, 1), plain = audioClip(5, 1)
    _ = AITimelineEdits.place([audioPlan(fresh, .newAudioBottom), audioPlan(numbered, .newAudioBottom, number: 3), audioPlan(plain, nil)],
                              insert: false, linkage: false, in: &mixed)
    checkEqual(mixed.location(of: numbered.id)?.track, .audio(2), "A3 sits right after the old tracks")
    checkEqual(mixed.location(of: fresh.id)?.track, .audio(3), "new_audio's track comes after the named ones")
    checkEqual(mixed.location(of: plain.id)?.track, .audio(0), "a clip naming no track takes the first free one, as a dropped file")
}

/// Video keeps the drop rule (a taken spot lifts the clip a track up); the note says so.
private func liftedVideoChecks() {
    var state = TimelineState()
    let first = videoClip(0, 4)
    state.mainClips = [first]
    let late = videoClip(1, 2)
    let notes = AITimelineEdits.place([AITimelineEdits.PlannedClip(clip: late, isAudio: false, target: .main, start: 1)],
                                      insert: false, linkage: false, in: &state)
    checkEqual(state.location(of: late.id)?.track, .overlay(0), "a video clip on a taken V1 spot is lifted to V2 (unchanged)")
    checkEqual(notes[late.id], AITrackLanding.Note(wanted: .main, reason: .busy(first.id)), "…and noted with the clip in the way")
    var plain = TimelineState()
    let notesOnEmpty = AITimelineEdits.place([AITimelineEdits.PlannedClip(clip: videoClip(0, 2), isAudio: false, target: .main, start: 0)],
                                             insert: false, linkage: false, in: &plain)
    check(notesOnEmpty.isEmpty, "a clip that lands where it asked is not noted")
}

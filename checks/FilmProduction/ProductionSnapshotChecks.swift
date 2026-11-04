import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 真实 TimelineState / Snapshot 的 metadata 回归；夹具只写合成字节，不打开、解码或剪辑实际媒体。
// 接入下一刀的 focused 检查，不把本文件未编译的草稿报告成通过。
func runProductionSnapshotChecks(root: URL) throws {
    typealias Snapshot = AIFilmProductionSnapshot
    typealias Graph = AIFilmProductionGraph
    typealias Plan = FilmProductionState
    let source = root.appendingPathComponent("production-synthetic.mp4")
    try Data(repeating: 7, count: 2048).write(to: source)
    var state = TimelineState()
    state.frameRate = .fps24
    state.mainClips = (0..<3).map { offset in
        var clip = EditClip(sourceURL: source, sourceDuration: 5, timelineStart: Double(offset) * 5)
        clip.info = MediaInfo(duration: 5, displaySize: CGSize(width: 320, height: 180), frameRate: 24,
            videoCodec: "synthetic", audioCodec: "synthetic", hasAudio: true, audioCanCopyToMP4: false, fileBytes: 2048)
        return clip
    }
    var plan = try productionFixture()
    for index in plan.shots.indices {
        let id = state.mainClips[index].id
        plan.shots[index].outputClipID = id
        plan.shots[index].boundSourceFingerprint = Snapshot.fingerprint(try Snapshot.source(id, state: state, picture: true))
    }
    let graph = try Graph.decode(plan)
    for index in plan.shots.indices {
        let clip = state.mainClips[index]
        let window = AIFilmProductionReadiness.window(clip, state: state)
        let actions = graph[index].film.shot.actions.map {
            Plan.ActionSamples(actionID: $0, sourceTimes: [1, 2], notes: "Synthetic caller-authored turn observation")
        }
        func seam(_ left: Int) throws -> Plan.SeamReview {
            .init(timelineTimes: AIFilmProductionSamples.seamRequests(
                left: AIFilmProductionReadiness.window(state.mainClips[left], state: state),
                right: AIFilmProductionReadiness.window(state.mainClips[left + 1], state: state)),
                notes: "Synthetic caller-authored both-side observation",
                fingerprint: Snapshot.fingerprint(try Snapshot.authoredSeam(graph[left], graph[left + 1], state: state)))
        }
        plan.shots[index].review = .init(sourceTimes: window.sourceRequests, notes: "Synthetic early/tail observation", actionSamples: actions,
            sourceFingerprint: Snapshot.fingerprint(try Snapshot.authoredSource(graph[index], state: state)),
            previous: index > 0 ? try seam(index - 1) : nil, next: index + 1 < 3 ? try seam(index) : nil)
    }
    state.production = plan
    let observed = try Graph.decode(plan)
    let ready = AIFilmProductionReadiness.inspect(plan, shots: observed, state: state)
    check(ready["shots"]!.arrayValue!.allSatisfy { $0["output_observations_current"] == true }, "source/action/both-seam observations match their current snapshots")
    check(ready["shots"]!.arrayValue!.allSatisfy { $0["input_anchor_current"] == false }, "output observations do not invent verified input anchors")
    let originalSource = try Snapshot.authoredSource(observed[0], state: state)
    let originalSeam = try Snapshot.authoredSeam(observed[0], observed[1], state: state)
    var moved = state
    moved.mainClips[1].sourceStart = 0.25
    check(try Snapshot.authoredSeam(observed[0], observed[1], state: moved) != originalSeam, "same UUID source trim invalidates previous seam")
    check(try Snapshot.authoredSeam(observed[1], observed[2], state: moved) != Snapshot.authoredSeam(observed[1], observed[2], state: state), "same UUID trim invalidates next seam too")
    check(try Snapshot.authoredSource(observed[0], state: moved) == originalSource, "neighbor trim does not invalidate unchanged own source observations")
    var replacement = try productionFixture(prompt: "A changed middle render", revisions: [2, 2, 2])
    for index in replacement.shots.indices {
        replacement.shots[index].outputClipID = plan.shots[index].outputClipID
        replacement.shots[index].boundSourceFingerprint = plan.shots[index].boundSourceFingerprint
        replacement.shots[index].review = plan.shots[index].review
    }
    let revised = try Graph.decode(replacement)
    check(try Snapshot.authoredSource(revised[0], state: state) == originalSource, "neighbor-only render/revision change keeps own source observation")
    check(try Snapshot.authoredSeam(revised[0], revised[1], state: state) != originalSeam, "neighbor-only render change invalidates seam")
    var overlay = EditClip(sourceURL: root.appendingPathComponent("missing-hidden.mp4"), sourceDuration: 3, timelineStart: 4)
    overlay.isHidden = true
    var layered = state
    layered.overlayTracks = [EditLane(clips: [overlay])]
    check(try Snapshot.authoredSeam(observed[0], observed[1], state: layered) == originalSeam, "hidden overlay does not cause a file read or affect seam")
    overlay.isHidden = false; overlay.sourceURL = source
    layered.overlayTracks = [EditLane(clips: [overlay], isHidden: true)]
    check(try Snapshot.authoredSeam(observed[0], observed[1], state: layered) == originalSeam, "hidden lane is excluded from composed seam")
    layered.overlayTracks[0].isHidden = false
    check(try Snapshot.authoredSeam(observed[0], observed[1], state: layered) != originalSeam, "visible overlapping overlay changes composed seam")
    try productionSubtitleSnapshots(state, observed: observed)
    let cue = Plan.SoundCue(id: "room", shotIDs: ["a", "b", "c"], layer: .environment, purpose: "Synthetic continuous bed", at: 0, duration: 15)
    let mix = try Snapshot.cue(cue, shots: observed, state: state)
    var audio = state; audio.mainVolume = 0.5
    check(try Snapshot.cue(cue, shots: observed, state: audio) != mix, "contributing track fader invalidates sound alignment")
    check(try Snapshot.authoredSource(observed[0], state: audio) == originalSource, "track fader does not invalidate source picture observation")
    audio = state; audio.masterVolume = 0.5
    check(try Snapshot.cue(cue, shots: observed, state: audio) != mix, "master fader invalidates sound alignment")
    audio = state; audio.mainClips[0].isMuted = true
    check(try Snapshot.cue(cue, shots: observed, state: audio) != mix, "clip mute invalidates sound alignment")
    check(try Snapshot.authoredSource(observed[0], state: audio) == originalSource, "clip mute does not invalidate source picture observation")
    audio = state; audio.masterVolume = .nan
    do { _ = try Snapshot.cue(cue, shots: observed, state: audio); check(false, "nonfinite mix cannot collapse to a fallback JSON fingerprint") }
    catch { check(true, "nonfinite mix cannot collapse to a fallback JSON fingerprint") }
    var invalid = state; invalid.mainClips[0].sourceDuration = .greatestFiniteMagnitude; invalid.mainClips[0].speed = 0.1
    do { _ = try Snapshot.source(invalid.mainClips[0].id, state: invalid, picture: true); check(false, "overflowing source geometry cannot produce an identity") }
    catch { check(true, "overflowing source geometry cannot produce an identity") }
    invalid = state; invalid.mainClips[0].speed = 0.01
    do { _ = try Snapshot.source(invalid.mainClips[0].id, state: invalid, picture: true); check(false, "inconsistent legacy speed cannot claim the wrong used timeline window") }
    catch { check(true, "inconsistent legacy speed cannot claim the wrong used timeline window") }
    try Data(repeating: 8, count: 4096).write(to: source)
    check(try Snapshot.authoredSource(observed[0], state: state) != originalSource, "same path/UUID with changed source bytes is not old evidence")
}

private func productionSubtitleSnapshots(_ state: TimelineState, observed: [AIFilmProductionGraph.Shot]) throws {
    typealias Snapshot = AIFilmProductionSnapshot
    func seam(_ value: TimelineState) throws -> JSONValue { try Snapshot.authoredSeam(observed[0], observed[1], state: value) }
    var near = state
    near.projectSubtitleStyle = BurnInStyle(name: "Synthetic effective app style")
    near.subtitle = SubtitleDocumentModel(cues: [SubtitleCue(index: 1, start: 4, end: 6, text: "Near cut")])
    let original = try seam(near)
    var changed = near; changed.projectSubtitleStyle!.fontSize += 1
    check(try seam(changed) != original, "captured effective style invalidates affected subtitle seam")
    changed = near; changed.projectSubtitleStyle!.name = "Renamed only"; changed.projectSubtitleStyle!.id = UUID()
    check(try seam(changed) == original, "style preset identity/name is not a visual change")
    changed = near; changed.subtitle!.cues.append(.init(index: 2, start: 12, end: 13, text: "Far from this cut"))
    check(try seam(changed) == original, "far subtitle edits do not invalidate unrelated seam")
    changed.subtitle!.cues[0].index = 100
    check(try seam(changed) == original, "far subtitle reindex does not invalidate unrelated seam")
    changed = near; changed.subtitleHidden = true
    check(try seam(changed) != original, "hiding visible subtitle invalidates seam")
    let hidden = try seam(changed); changed.projectSubtitleStyle!.fontSize += 1
    check(try seam(changed) == hidden, "global style with no visible overlapping subtitle does not affect seam")
    changed = near; changed.projectSubtitleStyle = nil
    do { _ = try seam(changed); check(false, "uncaptured global style must not invent a snapshot") }
    catch { check(true, "uncaptured global style refuses affected seam") }
}

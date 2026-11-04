import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 真实渲染副本/AudioEngineConfig 的属性反例；合成非空文件只供 stat，不读媒体、不运行 scene DSP。
func runProductionTransitionSnapshotChecks(root: URL) throws {
    typealias Snapshot = AIFilmProductionSnapshot
    let source = root.appendingPathComponent("transition-synthetic.mp4")
    let replacement = root.appendingPathComponent("transition-replacement.mp4")
    try Data(repeating: 3, count: 2048).write(to: source)
    try Data(repeating: 4, count: 3072).write(to: replacement)
    func clip(at: Double, start: Double, duration: Double, asset: Double, audio: Bool = true) -> EditClip {
        var value = EditClip(sourceURL: source, sourceStart: start, sourceDuration: duration, timelineStart: at)
        value.info = MediaInfo(duration: asset, displaySize: CGSize(width: 320, height: 180), frameRate: 24,
            videoCodec: "synthetic", audioCodec: audio ? "synthetic" : nil, hasAudio: audio, audioCanCopyToMP4: false, fileBytes: 2048)
        return value
    }
    func graph(_ state: TimelineState) throws -> [AIFilmProductionGraph.Shot] {
        var plan = try productionFixture()
        for index in plan.shots.indices {
            plan.shots[index].outputClipID = state.mainClips[index].id
            plan.shots[index].boundSourceFingerprint = Snapshot.fingerprint(try Snapshot.source(state.mainClips[index].id, state: state, picture: true))
        }
        return try AIFilmProductionGraph.decode(plan)
    }
    var state = TimelineState()
    state.frameRate = .fps24
    state.mainClips = [clip(at: 0, start: 0, duration: 4, asset: 8),
                       clip(at: 4, start: 1, duration: 4, asset: 8),
                       clip(at: 8, start: 0, duration: 4, asset: 8)]
    state.mainClips[0].transitionAfter = .crossFade
    state.mainClips[0].transitionDuration = 1
    let shots = try graph(state)
    let cue = FilmProductionState.SoundCue(id: "after-cut", shotIDs: ["b"], layer: .environment,
        purpose: "Synthetic B-only spotting including audible A handle", at: 4.1, duration: 0.2)
    let baseline = try Snapshot.cue(cue, shots: shots, state: state)
    let actual = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
    check(actual.tracks.flatMap(\.segments).contains { $0.clipID == state.mainClips[0].id && $0.end > 4.3 },
          "actual engine lends A audio beyond its raw 4-second end into the B-only cue")
    var changed = state; changed.mainClips[0].volume = 0.25
    check(try Snapshot.cue(cue, shots: shots, state: changed) != baseline, "borrowed preceding audio volume invalidates B-only sound alignment")
    changed = state; changed.mainClips[0].isMuted = true
    check(try Snapshot.cue(cue, shots: shots, state: changed) != baseline, "muting borrowed preceding audio invalidates B-only sound alignment")
    changed = state; changed.mainClips[0].sourceURL = replacement
    check(try Snapshot.cue(cue, shots: shots, state: changed) != baseline, "replacing borrowed preceding audio source invalidates B-only sound alignment")

    var silentLeft = state
    silentLeft.mainClips[0].isMuted = true
    let beforeFade = try Snapshot.cue(cue, shots: shots, state: silentLeft)
    let ownB = try Snapshot.authoredSource(shots[1], state: silentLeft)
    silentLeft.mainClips[0].transitionDuration = 0.5
    check(try Snapshot.authoredSource(shots[1], state: silentLeft) == ownB, "left transition change does not alter B raw source identity")
    check(try Snapshot.cue(cue, shots: shots, state: silentLeft) != beforeFade,
          "silent-left transition still changes the actual B gain envelope and invalidates sound alignment")
    check(baseline["mix"]?["scene_compensation_measured"] == false, "metadata snapshot never claims scene loudness compensation was measured")

    var short = state
    short.mainClips[0].transitionAfter = .none
    short.mainClips[1] = clip(at: 4, start: 0, duration: 1, asset: 1)
    short.mainClips[1].transitionAfter = .crossFade
    short.mainClips[1].transitionDuration = 0.5
    short.mainClips[2] = clip(at: 5, start: 2, duration: 4, asset: 8)
    let shortShots = try graph(short)
    let seam = try Snapshot.authoredSeam(shortShots[0], shortShots[1], state: short)
    let rendered = short.expandingTransitionHandles()
    check(rendered.mainClips[2].timelineStart < short.mainClips[1].timelineEnd,
          "actual render borrows C head into the short B tail covered by the A-B review")
    var thirdChanged = short
    thirdChanged.mainClips[2].placement = .init(centerX: 0.5, centerY: 0.5, width: 1.1, height: 1.1)
    check(try Snapshot.authoredSeam(shortShots[0], shortShots[1], state: thirdChanged) != seam,
          "third shot borrowed picture transform invalidates the earlier A-B composed seam")
    thirdChanged = short; thirdChanged.mainClips[2].sourceURL = replacement
    check(try Snapshot.authoredSeam(shortShots[0], shortShots[1], state: thirdChanged) != seam,
          "third shot borrowed source identity invalidates the earlier A-B composed seam")
    check(try Snapshot.authoredSource(shortShots[0], state: thirdChanged) == Snapshot.authoredSource(shortShots[0], state: short),
          "unaffected A own-source evidence survives C-only replacement")
}

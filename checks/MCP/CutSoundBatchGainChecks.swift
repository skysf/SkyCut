import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// Checks every seam in the final batch, including the same middle sound used twice. Measures and reports must agree
// after all edits; order, disconnected components, curves, faders and clamping are exercised through the public planner.
func runCutSoundBatchGainChecks() {
    batchChainChecks()
    batchSeparatedChecks()
    batchDisconnectedChecks()
    batchClampAndAtomicChecks()
}

private func batchChainChecks() {
    for levels in [[-10.0, -20, -30], [-30, -20, -10], [-10, -30, -20], [-30, -10, -20], [-20, -20, -20]] {
        let before = batchGainState(count: levels.count)
        var state = before
        let cuts = CutSoundCut.everyMainCut(in: state)
        let inputs = (0..<cuts.count).map { CutSoundPlanner.Inputs(material: .init(outgoing: levels[$0], incoming: levels[$0 + 1])) }
        do {
            let done = try CutSoundPlanner.run(.init(mode: .gain), cuts: cuts, inputs: inputs, skipsSilent: true, in: &state)
            checkFinalBatch(done.outcomes, before: before, after: state)
            for (index, clip) in state.mainClips.enumerated() {
                checkNear(levels[index] + clip.volumeLineDecibels(atTimeline: clip.timelineStart), levels.min()!,
                          "batch gain \(levels): every final sound meets the quietest without raising noise")
            }
            var reverse = before
            _ = try CutSoundPlanner.run(.init(mode: .gain), cuts: cuts.reversed(), inputs: inputs.reversed(), skipsSilent: true, in: &reverse)
            check(reverse == state, "batch gain is independent of cut traversal order")
            checkEqual(state.mainClips.map(\.timelineStart), before.mainClips.map(\.timelineStart), "batch gain never moves pictures")
        } catch { check(false, "batch gain failed: \(error)") }
    }
}

private func batchSeparatedChecks() {
    var separated = batchGainState(count: 3)
    for clip in separated.mainClips { _ = ClipSoundSeparation.separate(clip.id, in: &separated) }
    separated.audioTracks[0].volume = 0.5
    for lane in separated.audioTracks.indices {
        for index in separated.audioTracks[lane].clips.indices {
            let clip = separated.audioTracks[lane].clips[index]
            separated.audioTracks[lane].clips[index].volumeCurve = KeyframeTrack(keys: [
                Keyframe(time: clip.sourceStart, value: -3), Keyframe(time: clip.sourceStart + clip.sourceDuration, value: -1)
            ])
        }
    }
    let before = separated
    let cuts = CutSoundCut.everyMainCut(in: separated)
    let inputs = [CutSoundPlanner.Inputs(material: .init(outgoing: -10, incoming: -20)),
                  CutSoundPlanner.Inputs(material: .init(outgoing: -20, incoming: -30))]
    do {
        let done = try CutSoundPlanner.run(.init(mode: .gain), cuts: cuts, inputs: inputs, skipsSilent: true, in: &separated)
        checkFinalBatch(done.outcomes, before: before, after: separated)
        check(separated.mainClips == before.mainClips, "batch gain adjusts linked separated sounds, not their muted pictures")
    } catch { check(false, "curved separated batch failed: \(error)") }

}

private func batchDisconnectedChecks() {
    var disconnected = batchGainState(count: 5)
    disconnected.mainClips[2].isMuted = true
    let disconnectedBefore = disconnected
    let disconnectedInputs = [(-10.0, -20.0), (-20, -40), (-40, -30), (-30, -35)].map {
        CutSoundPlanner.Inputs(material: .init(outgoing: $0.0, incoming: $0.1))
    }
    do {
        let done = try CutSoundPlanner.run(.init(mode: .gain), cuts: CutSoundCut.everyMainCut(in: disconnected),
                                           inputs: disconnectedInputs, skipsSilent: true, in: &disconnected)
        checkEqual(done.skipped.count, 2, "silent middle shot breaks the batch into independent components")
        checkFinalBatch(done.outcomes, before: disconnectedBefore, after: disconnected)
        checkNear(disconnected.mainClips[0].volumeLineDecibels(atTimeline: 0), -10, "first component keeps its own quietest level")
        checkNear(disconnected.mainClips[3].volumeLineDecibels(atTimeline: 12), -5, "second component keeps its own quietest level")
    } catch { check(false, "disconnected batch failed: \(error)") }

}

private func batchClampAndAtomicChecks() {
    var clamped = batchGainState(count: 3)
    let clampBefore = clamped
    let clampInputs = [CutSoundPlanner.Inputs(material: .init(outgoing: 0, incoming: -70)),
                       CutSoundPlanner.Inputs(material: .init(outgoing: -70, incoming: -70))]
    do {
        let done = try CutSoundPlanner.run(.init(mode: .gain), cuts: CutSoundCut.everyMainCut(in: clamped),
                                           inputs: clampInputs, skipsSilent: true, in: &clamped)
        check(done.outcomes[0].notes.contains { $0.contains("not fully matched") }, "a volume-floor residual is reported honestly")
        checkNear(done.outcomes[0].gains.first?.requested, -70, "clamped batch reports the requested total attenuation")
        checkNear(done.outcomes[0].gains.first?.applied, -60, "clamped batch reports the actual total attenuation")
    } catch { check(false, "clamped batch failed: \(error)") }
    var invalid = clampBefore
    checkThrows("unmeasured second seam rejects the whole batch") {
        _ = try CutSoundPlanner.run(.init(mode: .gain), cuts: CutSoundCut.everyMainCut(in: invalid),
                                   inputs: [clampInputs[0], .init()], skipsSilent: true, in: &invalid)
    }
    check(invalid == clampBefore, "a failed batch is atomic")
    var conflict = clampBefore
    let repeated = CutSoundCut.everyMainCut(in: conflict)[0]
    checkThrows("inconsistent shared-sound constraints are refused atomically") {
        _ = try CutSoundPlanner.run(.init(mode: .gain), cuts: [repeated, repeated],
                                   inputs: [.init(material: .init(outgoing: -10, incoming: -20)),
                                            .init(material: .init(outgoing: -10, incoming: -30))], skipsSilent: true, in: &conflict)
    }
    check(conflict == clampBefore, "conflicting shared-sound gains change nothing")
    var explicit = clampBefore
    _ = try? CutSoundPlanner.run(.init(mode: .gain, gainDB: -3), cuts: CutSoundCut.everyMainCut(in: explicit), inputs: [], skipsSilent: true, in: &explicit)
    checkNear(explicit.mainClips[1].volumeLineDecibels(atTimeline: 4), -3, "explicit gain_db retains per-cut behavior")
    checkNear(explicit.mainClips[2].volumeLineDecibels(atTimeline: 8), -3, "explicit gain_db also applies to the final incoming sound")
}

private func batchGainState(count: Int) -> TimelineState {
    var state = TimelineState()
    state.mainClips = (0..<count).map { cutShot(URL(fileURLWithPath: "/synthetic/batch-\($0).mp4"), Double($0) * 4, 4, source: 10) }
    return state
}

private func checkFinalBatch(_ outcomes: [CutSoundOutcome], before: TimelineState, after: TimelineState) {
    for outcome in outcomes {
        let reply = CutSoundReport.json([outcome], in: after, ids: AIShortIDs(state: after))["cuts"]?.arrayValue?.first
        var final: [Double] = []
        for (side, id, time, level) in [("out", outcome.outgoing, outcome.cut.time - CutSoundWindows.middle, outcome.levels?.outgoing),
                                  ("in", outcome.incoming, outcome.cut.time + CutSoundWindows.middle, outcome.levels?.incoming)] {
            guard let id, let old = before.clip(with: id), let new = after.clip(with: id), let level else {
                check(false, "batch outcome must identify both measured sounds"); continue
            }
            let applied = new.volumeLineDecibels(atTimeline: time) - old.volumeLineDecibels(atTimeline: time)
            checkNear(outcome.gains.first { $0.clip == id }?.applied ?? 0, applied, "each seam reports its sound's final total gain")
            checkNear(reply?[side]?["gain_db"]?.doubleValue ?? 0, (applied * 10).rounded() / 10,
                      "the actual cut report serializes the final total gain")
            final.append(level + applied)
        }
        check(final.count == 2 && abs(final[0] - final[1]) < 1e-6, "every final seam stays matched after the entire batch (\(final))")
    }
}

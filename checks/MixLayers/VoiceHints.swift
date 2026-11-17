import Foundation
import SrtFlowMCPKit

// Exercise the real voice report with controlled ESTOI results: the grey hint stays below the tiers and only names
// one added main masker. No recordings are needed. The full offline-render path is exercised in Voice.swift.

func checkVoiceHints() {
    group("3b. Voice hints: boundaries, provenance and report counts")
    let cases: [(Double, AIListenVoicePlan.Kind, Bool, String, Double, Bool)] = [
        (0.48, .effects, false, "A2", 0.27, true),
        (0.445, .music, false, "A2", 0.29, true),
        (0.30, .music, false, "A2", 0.30, true),
        (0.499, .other, false, "A2", 0.25, true),
        (0.50, .effects, false, "A2", 0.30, false),
        (0.553, .other, false, "A2", 0.41, false),
        (0.48, .other, false, "A2", 0.249, false),
        (0.48, .clipSound, false, "A2", 0.40, false),
        (0.48, .voice, false, "A2", 0.40, false),
        (0.48, .effects, true, "A2", 0.40, false),
        (0.48, .effects, false, "rest", 0.40, false),
        (0.39, .effects, false, "A2", 0.40, false),
        (0.199, .music, false, "A2", 0.40, false)
    ]
    for (score, kind, voice, name, removed, expected) in cases {
        let report = hintReport(score: score, kind: kind, isVoice: voice, name: name, removed: removed)
        let line = report["lines"]?.arrayValue?.first
        check((line?["hint"] != nil) == expected,
              "hint for ESTOI \(score), \(kind.rawValue), voice=\(voice), \(name), removal +\(removed): \(expected)")
        check(report["summary"]?["may_be_loud"]?.intValue == (expected ? 1 : nil), "only hints count as may_be_loud")
        if kind == .voice || voice {
            check(line?["verdict"]?.stringValue == "two_voices", "a known voice-over masker counts even when it is not a requested voice track")
        }
        if expected {
            check(line?["verdict"]?.stringValue == "clear"
                      && line?["hint"]?.stringValue == "clear, but \(name) may be loud — try 3–6 dB lower",
                  "the grey suggestion names its layer and leaves the verdict clear")
            check(report["summary"]?["may_be_hard"] == nil && report["summary"]?["probably_unintelligible"] == nil,
                  "a hint does not count as either warning tier")
        }
    }
    let noMain = hintReport(score: 0.48, kind: .effects, removed: 0.30, gains: [])
    check(noMain["lines"]?.arrayValue?.first?["hint"] == nil, "no main masker: no hint")
    let secondary = hintReport(score: 0.48, kind: .clipSound, removed: 0.40, gains: [
        .init(id: "A2", whenRemoved: 0.40, whenLowered: 0.15, levelDBFS: -20),
        .init(id: "A3", whenRemoved: 0.30, whenLowered: 0.10, levelDBFS: -25)
    ])
    check(secondary["lines"]?.arrayValue?.first?["hint"] == nil, "an added secondary masker cannot replace the main one")
    checkDetachedProvenance()
}

private func hintReport(
    score: Double, kind: AIListenVoicePlan.Kind, isVoice: Bool = false, name: String = "A2", removed: Double,
    gains: [MaskerAttribution.Gain]? = nil
) -> [String: JSONValue] {
    let clip = AIListenVoicePlan.Clip(id: UUID(), name: "Synthetic narration", layer: 0, from: 1, to: 4)
    let layers: [AIListenVoicePlan.Layer] = [
        .init(stem: .init(name: "A1", tracks: [0]), isVoice: true, pieces: [.init(from: 1, to: 4, kind: .voice)]),
        .init(stem: .init(name: name, tracks: [1]), isVoice: isVoice, pieces: [.init(from: 1, to: 4, kind: kind)]),
        .init(stem: .init(name: "A3", tracks: [2]), isVoice: false, pieces: [.init(from: 1, to: 4, kind: .effects)])
    ]
    let result = MaskerAttribution.Result(
        estoi: .init(score: score, segmentScores: [score], speechFrames: 40),
        gains: gains ?? [.init(id: name, whenRemoved: removed, whenLowered: 0.10, levelDBFS: -20)],
        othersLowBandDBFS: -25, voiceDBFS: -22
    )
    return AIListenVoiceReport.json([.init(clip: clip, from: 1, to: 4, result: result)],
                                   plan: .init(layers: layers, clips: [clip], moreClips: 0, duration: 4), shortIDs: [clip.id: "c1"])
}

private func checkDetachedProvenance() {
    let picture = pictureClip(root.appendingPathComponent("camera.mov"), at: 1, duration: 3)
    let detached = picture.detachedAudio(linkGroup: nil)
    let provenance = AIListenVoicePlan.Provenance()
    check(provenance.kind(of: picture) == .clipSound && provenance.kind(of: detached) == .clipSound,
          "a picture's own sound stays clip_sound after Detach Audio")
    var state = baseState()
    let voice = audioClip(root.appendingPathComponent("narration.wav"), at: 1, duration: 3)
    state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [detached])]
    do {
        let plan = try AIListenVoicePlan.make("A1", state: state,
                                            config: AudioEngineConfig.make(from: state, measuringSceneCompensation: false),
                                            from: nil, to: nil, provenance: provenance)
        let layer = plan.layers.first { $0.stem.name == "A2" }
        check(layer?.kind(from: 1, to: 4) == .clipSound && layer?.isAddedSound(from: 1, to: 4) == false,
              "the production plan excludes detached camera sound from added-layer hints")
    } catch { check(false, "detached-audio plan failed: \(error)") }
}

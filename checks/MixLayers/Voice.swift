import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 3. listen voice=… (MCP-39): is each line of the narration covered? Synthetic signals only (no film audio in the repo):
// a speech-like voice (voiced syllables, three formants, a wandering pitch) on A1 in two lines a second apart; loud noise
// on A2 under the second line only; quiet "library music" (a chord) on A3 all along.
// - the plan: V tracks are refused with the reason (a voice inside a clip's own sound), auto finds the voice-over track by
//   its folder, every other track is a layer with its provenance;
// - the measurement: the voice clip splits into its two lines at the pause; line 1 is clear, line 2 probably unintelligible
//   with A2 the main masker (kind other) and removing it worth most; music is named music;
// - two voice tracks speaking at once → two_voices; the report's shape.

/// A speech-like voice: 180 ms voiced syllables with 70 ms gaps, pitch wandering around 140 Hz, three formants.
private func syllable(_ frame: Int) -> Float {
    let t = Double(frame) / 48_000
    let inSyllable = t.truncatingRemainder(dividingBy: 0.25)
    guard inSyllable < 0.18 else { return 0 }
    let envelope = sin(Double.pi * inSyllable / 0.18)
    let pitch = 140 + 15 * sin(2 * Double.pi * 3 * t)
    let formants = [(500.0, 1.0), (1500.0, 0.5), (2500.0, 0.25)]
    var value = 0.0
    for harmonic in 1 ... 24 {
        let frequency = pitch * Double(harmonic)
        let weight = formants.reduce(0.0) { $0 + $1.1 / (1 + pow((frequency - $1.0) / 200, 2)) }
        value += weight * sin(2 * Double.pi * frequency * t)
    }
    return Float(0.08 * envelope * value)
}

/// Two lines of 1.25 s with a 1 s pause between them (3.5 s).
private func voiceWAV(_ name: String, seed: Int = 0) -> URL {
    writeWAV(name, seconds: 3.5) { frame, _ in
        let t = Double(frame) / 48_000
        return (t < 1.25 || (2.25 ..< 3.5).contains(t)) ? syllable(frame + seed) : 0
    }
}

private func voiceTimeline() -> (state: TimelineState, voice: EditClip) {
    let voice = audioClip(voiceWAV("voice-lines.wav"), at: 1, duration: 3.5)
    var random = CheckNoise(seed: 31)
    let noise = writeWAV("voice-noise.wav", seconds: 1.4) { _, _ in random.next(1.5) }
    var chord = audioClip(writeWAV("voice-chord.wav", seconds: 5) { frame, _ in
        let t = Double(frame) / 48_000
        return Float(0.02 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)))
    }, at: 0.5, duration: 5)
    chord.remoteKey = "mus_check_chord"
    var state = baseState()
    state.audioTracks = [
        EditLane(clips: [voice]),
        EditLane(clips: [audioClip(noise, at: 3.2, duration: 1.4)]),
        EditLane(clips: [chord])
    ]
    return (state, voice)
}

private let voiceProvenance = AIListenVoicePlan.Provenance(library: ["mus_check_chord": .music], folders: ["Voiceovers": .voice])

func checkVoiceCheck() {
    group("3. listen voice=…：每一句人声被谁盖住、盖得多厉害（MCP-39）")
    let (state, voice) = voiceTimeline()
    let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
    // The plan.
    for refused in ["V1", "main"] {
        do {
            _ = try AIListenVoicePlan.make(refused, state: state, config: config, from: nil, to: nil, provenance: voiceProvenance)
            check(false, "voice=\(refused) must be refused")
        } catch let error as AIToolError {
            check(error.message.contains("own sound"), "voice=\(refused) is refused because a voice inside a clip's own sound can't be measured (\(error.message))")
        } catch { check(false, "voice=\(refused): \(error)") }
    }
    check((try? AIListenVoicePlan.make("A9", state: state, config: config, from: nil, to: nil, provenance: voiceProvenance)) == nil,
          "a track that is not in the mix is refused")
    guard let plan = try? AIListenVoicePlan.make("a1", state: state, config: config, from: nil, to: nil, provenance: voiceProvenance) else {
        check(false, "voice=A1 made no plan"); return
    }
    check(plan.layers.map(\.stem.name) == ["A1", "A2", "A3"] && plan.layers.map(\.isVoice) == [true, false, false],
          "the voice track first, every other audible track a layer of its own (\(plan.layers.map(\.stem.name)))")
    check(plan.layers[2].kind(from: 1, to: 2) == .music && plan.layers[1].kind(from: 3.3, to: 4) == .other,
          "library music is music, an unknown file is other")
    check(plan.clips.count == 1 && plan.clips.first?.id == voice.id, "one voice clip to check")
    // auto: the voice-over track by the folder SkyCut writes voice-overs to.
    var auto = state
    let folder = root.appendingPathComponent("Voiceovers", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let moved = folder.appendingPathComponent("voice-lines.wav")
    try? FileManager.default.copyItem(at: voice.sourceURL, to: moved)
    auto.audioTracks[0].clips[0].sourceURL = moved
    let autoPlan = try? AIListenVoicePlan.make("auto", state: auto, config: config, from: nil, to: nil, provenance: voiceProvenance)
    check(autoPlan?.layers.first?.stem.name == "A1", "voice=auto finds the track holding only voice-overs")
    // The measurement.
    guard let lines = try? AIListenVoiceMeasure.measure(plan, config: AudioEngineConfig.make(from: state)) else {
        check(false, "the voice check did not run"); return
    }
    check(lines.count == 2, "the clip splits into its two lines at the pause (\(lines.count))")
    guard lines.count == 2, let first = lines[0].result, let second = lines[1].result else { return }
    check(abs(lines[0].from - 1) < 0.05 && abs(lines[1].from - 3.25) < 0.05,
          "the lines are where the voice speaks on the timeline (\(lines[0].from), \(lines[1].from))")
    check(first.estoi.score > 0.8, "line 1 under quiet music is clear (ESTOI \(first.estoi.score))")
    check(second.estoi.score < 0.31 && second.gains.first?.id == "A2" && (second.gains.first?.whenRemoved ?? 0) > 0.3,
          "line 2 under loud noise: ESTOI \(second.estoi.score), A2 covers it most (removing it +\(second.gains.first?.whenRemoved ?? 0))")
    let report = AIListenVoiceReport.json(lines, plan: plan, shortIDs: [voice.id: "c1"])
    let listed = report["lines"]?.arrayValue ?? []
    check(listed.first?["verdict"]?.stringValue == "clear" && listed.last?["verdict"]?.stringValue == "probably_unintelligible",
          "verdicts: clear, probably_unintelligible (\(listed.map { $0["verdict"]?.stringValue ?? "" }))")
    let masker = listed.last?["maskers"]?.arrayValue?.first
    check(masker?["layer"]?.stringValue == "A2" && masker?["kind"]?.stringValue == "other" && listed.last?["low_150_db"] != nil
              && listed.last?["voice_db"] != nil && listed.last?["clip"]?.stringValue == "c1",
          "each line names its main masker and kind, the 20–150 Hz level next to the voice's, and its clip")
    check(report["summary"]?["probably_unintelligible"]?.intValue == 1 && report["summary"]?["lines"]?.intValue == 2,
          "the summary counts the verdicts")
    // Two voices at once.
    var duet = state
    duet.audioTracks.append(EditLane(clips: [audioClip(voiceWAV("voice-other.wav", seed: 977), at: 1, duration: 3.5)]))
    let duetConfig = AudioEngineConfig.make(from: duet, measuringSceneCompensation: false)
    if let duetPlan = try? AIListenVoicePlan.make("A1+A4", state: duet, config: duetConfig, from: nil, to: nil, provenance: voiceProvenance),
       let duetLines = try? AIListenVoiceMeasure.measure(duetPlan, config: AudioEngineConfig.make(from: duet)) {
        let verdicts = AIListenVoiceReport.json(duetLines, plan: duetPlan, shortIDs: [:])["lines"]?.arrayValue?.compactMap { $0["verdict"]?.stringValue } ?? []
        check(!verdicts.isEmpty && verdicts.allSatisfy { $0 == "two_voices" }, "two voices speaking at once are their own item (\(verdicts))")
    } else { check(false, "the two-voice check did not run") }
}

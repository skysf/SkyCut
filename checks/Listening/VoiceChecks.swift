import Foundation

// The verdict lines (VoiceClarity, the tiers the user approved 2026-11-16) and where a voice's lines are (VoiceLines).
// Pure values: the real render-and-measure path is in scripts/check-mix-layers.sh group 3.

func runVoiceChecks() {
    checkVoiceVerdicts()
    checkVoiceHints()
    checkVoiceLines()
}

private func checkVoiceHints() {
    let cases: [(Double?, VoiceClarity.Verdict, Bool, Double?, Bool, String)] = [
        (0.48, .clear, true, 0.27, true, "E34-like added rain"),
        (0.445, .clear, true, 0.29, true, "E35-like music"),
        (0.30, .clear, true, 0.30, true, "music can pass its tier below 0.41 and still get a hint"),
        (0.499, .clear, true, 0.25, true, "removal gain includes 0.25"),
        (0.50, .clear, true, 0.30, false, "ESTOI excludes 0.50"),
        (0.553, .clear, true, 0.41, false, "E36-like clear line"),
        (0.637, .clear, true, 0.40, false, "E39-like clear line"),
        (0.48, .clear, false, 0.40, false, "the main masker must be one added layer"),
        (0.48, .clear, true, 0.249, false, "removal gain below the boundary"),
        (0.48, .clear, true, 0.20, false, "removing it helps too little"),
        (0.39, .mayBeHard, true, 0.40, false, "no hint below the yellow tier"),
        (0.30, .probablyUnintelligible, true, 0.40, false, "no hint below the red tier"),
        (0.48, .twoVoices, true, 0.40, false, "overlapping voices have their own verdict"),
        (nil, .tooShort, true, 0.40, false, "no ESTOI means no hint"),
        (0.48, .clear, true, nil, false, "no main masker means no hint")
    ]
    for (estoi, verdict, added, removed, expected, label) in cases {
        checkEqual(VoiceClarity.hint(estoi: estoi, verdict: verdict, mainMaskerIsAddedLayer: added, removalGain: removed),
                   expected, label)
    }
}

private func checkVoiceVerdicts() {
    let cases: [(Double?, Bool, Bool, VoiceClarity.Verdict, String)] = [
        (0.30, false, false, .probablyUnintelligible, "0.30, not music: probably unintelligible"),
        (0.31, false, false, .mayBeHard, "0.31 is the edge: may be hard"),
        (0.409, false, false, .mayBeHard, "0.409: may be hard"),
        (0.41, false, false, .clear, "0.41 and up: clear"),
        (0.25, true, false, .clear, "music the main masker: 0.25 is not reported"),
        (0.199, true, false, .mayBeHard, "music the main masker: below 0.20 may be hard"),
        (0.9, false, true, .twoVoices, "another voice speaking: its own item whatever the ESTOI"),
        (nil, false, true, .twoVoices, "another voice speaking even when the line is short"),
        (nil, false, false, .tooShort, "no ESTOI: too short")
    ]
    for (estoi, music, otherVoice, expected, label) in cases {
        checkEqual(VoiceClarity.verdict(estoi: estoi, musicIsMainMasker: music, anotherVoiceSpeaking: otherVoice), expected, label)
    }
    checkEqual(VoiceClarity.Verdict.allCases.map(\.rawValue),
               ["clear", "may_be_hard", "probably_unintelligible", "two_voices", "too_short"], "the verdict names the AI reads")
}

private func checkVoiceLines() {
    let rate = 48_000.0
    // Two stretches of speech-like sound with 1.0 s of silence between them (the speech's own pause is 0.4 s: it stays one line).
    let first = TestSignals.speechLike(seconds: 2.5, rate: rate, seed: 3).map(Float.init)
    let second = TestSignals.speechLike(seconds: 2.0, rate: rate, seed: 4).map(Float.init)
    let samples = first + [Float](repeating: 0, count: Int(rate)) + second
    let lines = VoiceLines.split(samples, rate: rate)
    checkEqual(lines.count, 2, "two stretches a second apart are two lines; the 0.4 s pause inside one is not a line break")
    if lines.count == 2 {
        let silenceStart = Double(first.count) / rate, silenceEnd = silenceStart + 1
        check(Double(lines[0].upperBound) / rate <= silenceStart + 0.03 && Double(lines[1].lowerBound) / rate >= silenceEnd - 0.03,
              "the lines stop where the voice stops and start where it starts (\(Double(lines[0].upperBound) / rate), \(Double(lines[1].lowerBound) / rate))")
        check(lines[0].lowerBound < Int(0.2 * rate), "the first line starts with the first syllable (\(Double(lines[0].lowerBound) / rate) s)")
    }
    checkEqual(VoiceLines.split([Float](repeating: 0, count: Int(rate)), rate: rate).count, 0, "silence has no lines")
    // A quieter voice is still a voice: the 40 dB range is relative to its own loudest frame.
    let quiet = first.map { $0 * 0.1 }
    checkEqual(VoiceLines.split(quiet, rate: rate).count, 1, "a voice 20 dB quieter is still one line")
}

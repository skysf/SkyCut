import Foundation
import SrtFlowMCPKit

// 4. listen describe=true (MCP-42 / MCP-44): what a clip's own sound is, per 3 s window, as the AI reads it
// (AIListenSourceReport). Synthetic sound only: 3 s of a low drone (55 Hz with its harmonics), 3 s of white noise, 3 s of a
// major chord. SkyCut's traits land on the right windows (low_drone, broadband_noise, pitched); the classifier's labels (here a
// fixed set standing in for SoundLabelScores, whose real run is scripts/check-sound-labels.sh) are kept at most five per window,
// none under 0.05; words are counted per window and quoted; times are on the clip's timeline (start, source start, speed); a
// recogniser that was not asked says why.

private func sourceSound(rate: Double) -> [Float] {
    var random = CheckNoise(seed: 17)
    return (0 ..< Int(9 * rate)).map { index in
        let t = Double(index) / rate
        if t < 3 { return Float(0.3 * (sin(2 * .pi * 55 * t) + 0.5 * sin(2 * .pi * 110 * t) + 0.25 * sin(2 * .pi * 165 * t))) }
        if t < 6 { return random.next(0.4) }
        return Float(0.2 * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 554.4 * t) + sin(2 * .pi * 659.3 * t)))
    }
}

func checkSourceSound() {
    group("4. listen describe=true：一段原声每 3 秒是什么（SkyCut 的描述词 + 系统识别器每个标签自己的分数 + 有没有字）")
    let rate = 48_000.0
    let samples = sourceSound(rate: rate)
    // What the classifier says, per window (its real labels and scores come from Apple's model: scripts/check-sound-labels.sh).
    let scored = (0 ..< 8).map { SoundLabelScores.Label(name: "label\($0)", score: 0.9 - Double($0) * 0.12) }
    let labels = [0.0, 3, 6].map { SoundLabelScores.Window(start: $0, duration: 3, labels: scored) }
    let traits = SourceSoundDescription.describe(samples, sampleRate: rate)
    let words = AIListenSourceReport.Words.found([.init(start: 12.5, text: "hello"), .init(start: 13.1, text: "there"), .init(start: 18, text: "again")])
    // A clip from timeline 20 playing source 12–21 s at double speed: source 12 → 20, 15 → 21.5, 18 → 23.
    let report = AIListenSourceReport.json(traits: traits, labels: labels, words: words, readStart: 12, readEnd: 21,
                                           place: AIListenSourceReport.Place(start: 20, sourceStart: 12, speed: 2))
    let windows = report["windows"]?.arrayValue ?? []
    check(windows.count == 3 && windows.map { $0["from"]?.doubleValue } == [20, 21.5, 23],
          "three windows at the clip's timeline seconds (\(windows.map { $0["from"]?.doubleValue ?? -1 }))")
    let names = windows.map { $0["traits"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    check(names.count == 3 && names[0].contains("low_drone") && names[1].contains("broadband_noise") && names[2].contains("pitched"),
          "SkyCut's words: the drone, the noise, the chord (\(names))")
    check(windows.allSatisfy { ($0["labels"]?.arrayValue?.count ?? 0) <= AIListenSourceReport.labelsPerWindow }
              && windows.allSatisfy { ($0["labels"]?.arrayValue ?? []).allSatisfy { ($0["score"]?.doubleValue ?? 0) >= AIListenSourceReport.labelFloor } },
          "at most five labels per window, none under 0.05")
    check(windows.allSatisfy { $0["labels"]?.arrayValue?.first?["label"]?.stringValue == "label0" && $0["labels"]?.arrayValue?.count == 5 },
          "the strongest five of eight labels, strongest first")
    check(windows.map { $0["words"]?.intValue } == [2, 0, 1], "words counted per window (\(windows.map { $0["words"]?.intValue ?? -1 }))")
    check(report["summary"]?["words"]?.intValue == 3 && report["summary"]?["heard"]?.stringValue == "hello there again",
          "the summary counts the words and says what was heard")
    check(report["summary"]?["traits"]?["low_drone"]?.intValue == 1, "the summary counts each trait's windows")
    let unchecked = AIListenSourceReport.json(traits: traits, labels: labels, words: .notChecked("no speech model"),
                                              readStart: 0, readEnd: 9, place: AIListenSourceReport.Place())
    check(unchecked["summary"]?["words"]?.stringValue == "not checked: no speech model" && unchecked["windows"]?.arrayValue?.first?["words"] == nil,
          "not asked: says why, and no word counts")
    check(unchecked["note"]?.stringValue?.contains("not a verdict") == true, "the note says these are words, not a verdict")
}

import Foundation
import SrtFlowCore

// cut_speech 的切口最后落在哪（AISpeechCutPoints，2026-10-14）：AI 给的一刻落在量出来的停顿里就原样切；落在声音上才挪，
// 挪进这两个词之间真的停顿（段的开头离后面的声音最多 0.3 秒、结尾反过来），没有够长的停顿就切在最近的安静窗里，
// 都没有才按转写切并标出来；snap=false 一刀不挪；挪完两头碰到一起就照给的时间切；挪了超过 50ms 的报给 AI。
// 用例的转写都照识别器的毛病造：停顿后面第一个词的开口估早了、句末的词收早了 —— 用户报的两个切口
// （41.917 被挪到 42.125 切掉「When」的开头、71.75 被挪到 71.417 带进上一句的尾音）原样在这里。
// 案例：docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md。编法见 scripts/check-mcp.sh。

func runSpeechCutPointChecks() {
    checkPointsInPausesStay()
    checkPointsOnSpeechMove()
    checkWithoutTranscriptOrSnap()
    checkSpansAndReport()
    checkFillerEdgesFollowTheSound()
}

private func word(_ text: String, _ start: Double, _ end: Double) -> SpeechTranscript.Word {
    SpeechTranscript.Word(text: text, start: start, end: end, sourceStart: start, sourceEnd: end, confidence: nil)
}

private func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-6 } ?? false }

/// 一段电平：每 0.04 秒一个窗，`loud` 里的 −20 dB、其余 −60 dB（门限 −40 时就是停顿）。
private func levels(from: Double, to: Double, loud: [ClosedRange<Double>]) -> [AIAudioLevels.Window] {
    let count = Int(((to - from) / 0.04).rounded())
    return (0..<count).map { index in
        let start = from + Double(index) * 0.04
        let end = from + Double(index + 1) * 0.04
        let isLoud = loud.contains { $0.contains((start + end) / 2) }
        return AIAudioLevels.Window(start: start, end: end, meanSquare: isLoud ? 0.01 : 0.000_001, peak: isLoud ? 0.3 : 0.001)
    }
}

/// 用户的第一个切口：「…work. When I got」。转写把「When」估早了（41.70–42.05，声音 41.96 才开口），「work.」收早了
///（41.20，声音到 41.48）；「I」和「got」之间只空 0.08 秒。
private let when = [word("work.", 40.6, 41.2), word("When", 41.7, 42.05), word("I", 42.2, 42.3), word("got", 42.4, 42.7)]
private let whenSound = levels(from: 40, to: 43.2, loud: [40...41.48, 41.96...42.48, 42.56...42.88])

/// 用户的第二个切口：「…it. So we」。转写把「So」估早了（71.60，声音 71.84 才开口），「it.」收早了（71.23，声音到 71.48）。
private let soWe = [word("it.", 70.9, 71.23), word("So", 71.6, 71.95), word("we", 72.05, 72.2)]
private let soWeSound = levels(from: 70, to: 72.8, loud: [70.8...71.48, 71.84...72.24])

private func checkPointsInPausesStay() {
    let first = AISpeechCutPoints(words: when, levels: whenSound, silenceDB: -40)
    check(near(AISpeechCuts.startPoint(41.917, words: when), 42.125),
          "transcript only: 41.917 (in the real pause) is taken for the end of 'When' and moved to 42.125 — the bug")
    check(near(first.point(41.917, .start).time, 41.917), "with the sound: 41.917 is in the pause before 'When', so the cut stays there")
    checkEqual(first.point(41.917, .start).why, nil, "and is not reported as moved")
    let removeBefore = AISpeechCuts.requested([40...41.917], points: first)
    check(near(removeBefore.first?.end, 41.917), "removing up to 41.917 keeps all of 'When' (the transcript alone cut it at 42.125)")

    let second = AISpeechCutPoints(words: soWe, levels: soWeSound, silenceDB: -40)
    check(near(AISpeechCuts.onFrame(AISpeechCuts.startPoint(71.75, words: soWe), frame: 1.0 / 24), 1714.0 / 24),
          "transcript only: 71.75 is moved back to 71.417, into the end of the sentence before — the bug")
    check(near(second.point(71.75, .start).time, 71.75), "with the sound: 71.75 is in the pause before 'So', so the cut stays there")
    check(near(second.point(71.6, .start).time, 71.6),
          "the transcript's own start of 'So' (too early, but still in the pause) is used as is too")
    check(near(first.point(41.94, .start).time, 41.94) && near(first.point(42.0, .start).time, 42.0),
          "a time on the edge of a pause (within a level window) counts as in it: listen's silence edges are window edges")
}

private func checkPointsOnSpeechMove() {
    let points = AISpeechCutPoints(words: when, levels: whenSound, silenceDB: -40)
    // 「work.」的结尾照转写给（41.20），声音其实说到 41.48：转写的空隙中点 41.45 还在尾音上，挪进真的停顿。
    check(near(AISpeechCuts.endPoint(41.2, words: when), 41.45), "transcript only: the end of 'work.' goes to 41.45, still on its tail")
    let tail = points.point(41.2, .end)
    check(near(tail.time, 41.72), "with the sound: into the real pause 41.48–41.96, at its middle (got \(tail.time))")
    check(tail.why?.contains("pause") == true && !tail.onSpeech, "and says it moved into a pause (\(tail.why ?? "nil"))")
    // 「got」的开头：「I」和它之间只空 0.08 秒（不够一个停顿），切在那个安静的窗里，不跳过整个词去找远处的停顿。
    let gap = points.point(42.4, .start)
    check(near(gap.time, 42.5), "a short gap between words: the cut goes into its quiet window (got \(gap.time))")
    check(gap.why?.contains("quiet spot") == true, "and says so")
    check(near(points.point(42.7, .end).time, 43.0), "after the last word: the transcript's point is already in the pause, so it is used")
    // 一口气说下去：附近没有停顿也没有安静的窗，按转写切，标出来可能切到字。
    let fluent = AISpeechCutPoints(words: [word("a", 50.5, 50.8), word("b", 50.85, 51.2)],
                                   levels: levels(from: 50, to: 52, loud: [50...52]), silenceDB: -40)
    let onSpeech = fluent.point(50.85, .start)
    check(near(onSpeech.time, 50.825) && onSpeech.onSpeech, "no pause anywhere near: the transcript's gap, flagged as on speech")
}

private func checkWithoutTranscriptOrSnap() {
    let noTranscript = AISpeechCutPoints(words: [], levels: whenSound, silenceDB: -40)
    check(near(noTranscript.point(41.4, .start).time, 41.72),
          "no transcript: a start on speech moves into the nearest pause within 0.3 s (middle, at most 0.3 s before the sound)")
    let exact = AISpeechCutPoints(words: when, levels: whenSound, silenceDB: -40, snaps: false)
    check(near(exact.point(41.2, .end).time, 41.2), "snap=false: the cut is exactly where the AI said")
    check(near(exact.snapping.point(41.2, .end).time, 41.72), "filler and repeat edges still move (they are transcript times)")
    let noSound = AISpeechCutPoints(words: when, levels: nil, silenceDB: -40)
    check(near(noSound.point(41.917, .start).time, 42.125), "no readable sound: the transcript alone, as before")
}

private func checkSpansAndReport() {
    let points = AISpeechCutPoints(words: when, levels: whenSound, silenceDB: -40)
    // 只留「When」里的一小截：两头都会挪进同一个停顿、碰到一起 —— 照给的时间切，不许把整段都剪掉。
    let sliver = AISpeechCuts.outside([42.0...42.1], clip: 40...43.2, points: points)
    checkEqual(sliver.count, 2, "keeping a sliver inside one word still keeps it")
    check(near(sliver.first?.end, 42.0) && near(sliver.last?.start, 42.1), "cut exactly at the given times")

    let report = points.report([41.917...42.7, 40...41.2], clip: 40...43.2, frame: 1.0 / 30)
    checkEqual(report.moved.map(\.asked), [42.7, 41.2], "only times that moved more than 50 ms are listed; the clip edge is not")
    check(near(report.moved.first?.cutAt, 43.0) && near(report.moved.last?.cutAt, 1252.0 / 30),
          "with where the cut really is, rounded to frames like the cuts")
    check(report.moved.allSatisfy { $0.why.contains("pause") }, "and why")
    check(report.onSpeech.isEmpty, "nothing left on speech")
    let fluent = AISpeechCutPoints(words: [word("a", 50.5, 50.8), word("b", 50.85, 51.2)],
                                   levels: levels(from: 50, to: 52, loud: [50...52]), silenceDB: -40)
    checkEqual(fluent.report([50.85...51.5], clip: 50...52, frame: 1.0 / 30).onSpeech.count, 2,
               "cuts with no pause near them are reported as on speech")
}

private func checkFillerEdgesFollowTheSound() {
    // 转写把「um」放在 1.5–1.8，声音其实是 1.68–2.20：照转写的空隙中点（2.1）切会留下「um」的尾巴。
    let words = [word("So", 1.0, 1.3), word("um", 1.5, 1.8), word("I", 2.8, 2.9)]
    let sound = levels(from: 0.8, to: 3.2, loud: [1.0...1.28, 1.68...2.2, 2.84...3.0])
    let old = AISpeechCuts.fillerWords(words, points: AISpeechCutPoints(words: words, levels: nil, silenceDB: -40))
    check(near(old.first?.end, 2.1), "transcript only: the cut after 'um' is at 2.1, inside its real tail")
    let cut = AISpeechCuts.fillerWords(words, points: AISpeechCutPoints(words: words, levels: sound, silenceDB: -40, snaps: false))
    check(near(cut.first?.start, 1.5) && near(cut.first?.end, 2.5),
          "with the sound (even with snap=false, which is only for given times): 1.5–2.5, all of the real 'um' (got \(cut))")
}

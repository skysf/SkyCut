import Foundation
import SrtFlowCore

// 判切口要听的那一份（AISpeechHearing，2026-10-18）：cut_speech 和 listen cuts=true 用同一份输入 —— 整个素材文件的电平、按整个文件量的
// 门限、整个文件估过开口的词。用 L16 课程原片真量出来的电平（「available.」的尾音里有一格 46 ms 的低谷，之后尾音又响了 0.1 秒、真停顿
// 才开始）和转写缓存里的原样：测试员看到 cut_speech 把 77.417 挪到 77.75，剪辑点检查却说 quiet_spot（可以不改）、同时又建议 77.717；
// 现在检查报 on_speech、切到「available.」、建议的就是 cut_speech 落刀的 77.75。变速的片段上两个工具也判得一样。
// 案例：docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md。编法见 scripts/check-mcp.sh。

func runSpeechHearingChecks() {
    checkHearingInputs()
    checkHearingL16()
    checkHearingAxes()
}

/// L16 原片（44.1 kHz）第 1614 个窗起（74.954 秒；一窗 2048 帧 ≈ 46 ms，和 AIAudioLevels.windows 一样从文件开头对齐）到 79 秒的电平（dB）。
/// 第 53 个（77.415–77.462）是尾音里的低谷 −48.2，后面 −37.6 / −41.0 / −44.3 还是尾音，第 57–62 个是真停顿，第 63 个「The」开口。
private let l16FirstWindow = 1614
private let l16Decibels: [Double] = [
    -49.9, -27.1, -24.5, -22.8, -26.2, -28.8, -24.0, -27.3, -32.7, -46.7, -46.0, -34.7, -23.4, -24.6, -30.2, -22.8, -24.8, -30.6,
    -29.5, -27.5, -26.0, -28.4, -38.7, -31.1, -29.6, -28.8, -29.9, -33.5, -37.2, -38.8, -60.0, -41.0, -45.0, -27.4, -23.9, -23.2,
    -27.9, -31.6, -39.5, -41.4, -30.2, -28.6, -30.5, -50.6, -35.2, -33.6, -42.8, -35.6, -24.2, -24.5, -26.0, -29.9, -34.3, -48.2,
    -37.6, -41.0, -44.3, -60.0, -58.7, -59.2, -60.0, -60.0, -52.2, -24.9, -38.5, -28.4, -22.8, -24.1, -31.9, -31.0, -50.4, -29.0,
    -26.1, -38.5, -50.2, -47.8, -34.3, -23.7, -21.1, -22.2, -33.1, -40.6, -41.2, -23.2, -23.7, -23.9, -25.3
]
private let span = 2048.0 / 44100

private func level(_ start: Double, _ db: Double) -> AIAudioLevels.Window {
    let amplitude = pow(10, db / 20)
    return AIAudioLevels.Window(start: start, end: start + span, meanSquare: amplitude * amplitude, peak: amplitude)
}

/// 整个文件：前面 0–74.95 秒说 0.6 秒（−25 dB）、停 0.4 秒（−60 dB）这样交替（整个文件量出来的门限落在 −45，同真文件：量出 −48.5、
/// 夹到 −45），后面接真量的那一截。
private func l16Levels() -> [AIAudioLevels.Window] {
    let before = (0..<l16FirstWindow).map { k in
        let start = Double(k) * span
        return level(start, start.truncatingRemainder(dividingBy: 1) < 0.6 ? -25 : -60)
    }
    return before + l16Decibels.enumerated().map { offset, db in level(Double(l16FirstWindow + offset) * span, db) }
}

/// 转写缓存里这一句的原样：识别器把「available.」收在 77.16，「The」从 77.22 起（尾音和停顿都并进了它）。
private let l16Transcript = [
    TimedWord(text: " currently", start: 76.02, end: 76.44, confidence: 0.993),
    TimedWord(text: " available.", start: 76.44, end: 77.16, confidence: 0.99),
    TimedWord(text: " The", start: 77.22, end: 77.94, confidence: 0.964),
    TimedWord(text: " aspect", start: 77.94, end: 78.30, confidence: 0.99),
    TimedWord(text: " ratios", start: 78.30, end: 78.84, confidence: 0.998)
]

private func checkHearingInputs() {
    let hearing = AISpeechHearing(levels: l16Levels(), transcript: l16Transcript)
    check(hearing.measuredDB.map { $0 < AIAudioLevels.defaultSilenceDB } == true,
          "the threshold is measured over the whole file (got \(hearing.measuredDB ?? 0))")
    checkEqual(hearing.silenceDB(nil), AIAudioLevels.defaultSilenceDB, "…and is never stricter than listen's default -45")
    checkEqual(hearing.silenceDB(-38), -38, "silence_db from the AI wins")
    // 词和 transcribe 读出来的同一份：停顿后面第一个词估过开口（「The」从 77.94 − 0.38 = 77.56 起），源秒。
    let window = SubtitleClipWindow(clipID: UUID(), assetFingerprint: "", sourceStart: 75, sourceEnd: 79, timelineStart: 0)
    let transcribed = SpeechTranscript.sentences(words: l16Transcript, window: window).flatMap(\.words)
    checkEqual(hearing.words.map(\.text), transcribed.map(\.text), "the words are the ones transcribe reads")
    checkEqual(hearing.words.map(\.start), transcribed.map(\.sourceStart), "…with the same estimated starts, in source seconds")
    check(hearing.words.first { $0.text == "The" }.map { abs($0.start - 77.56) < 1e-9 } == true, "…'The' starts at its estimated 77.56")
    check(hearing.hasTranscript, "a transcript was given")

    let silent = AISpeechHearing(levels: nil, transcript: nil)
    check(silent.words.isEmpty && !silent.hasTranscript && silent.measuredDB == nil, "no sound, no transcript: nothing")
    checkEqual(silent.silenceDB(nil), AIAudioLevels.defaultSilenceDB, "…and the threshold falls back to -45")
}

private func checkHearingL16() {
    let hearing = AISpeechHearing(levels: l16Levels(), transcript: l16Transcript)
    let frame = 1.0 / 24
    // cut_speech 在整段（时间线 0 = 源 0）上只留 71.458–77.417（1715–1858 帧）：77.417 在尾音上，挪进停顿。
    let whole = videoClip(0, 162.25, asset: 162.25)
    let report = hearing.points(silenceDB: nil, clip: whole).report([1715 * frame...1858 * frame], clip: 0...162.25, frame: frame)
    let cutAt = report.moved.first { abs($0.asked - 1858 * frame) < 1e-9 }?.cutAt
    check(cutAt.map { abs($0 - 77.75) < 1e-9 } == true, "cut_speech moves the cut after 'available.' into the pause: 77.75 (got \(cutAt ?? -1))")
    // 剪完的那一段放在时间线 17.375 上，剪辑点检查判它的尾巴：同一个源时刻。
    let piece = videoClip(417 * frame, 143 * frame, asset: 162.25, sourceStart: 1715 * frame)
    let tail = AICutCheck.side(of: piece, end: .end, at: piece.timelineEnd, sound: piece, points: hearing.points(silenceDB: nil), frame: frame)
    guard case .onSpeech(let word, _) = tail.verdict else {
        return check(false, "the check says the tail cuts into speech, like cut_speech (it said quiet_spot), got \(tail.verdict)")
    }
    checkEqual(word, "available.", "…into 'available.' (the transcript's 'The' covers 77.417 but starts after the pause)")
    check(tail.suggestedSource.map { abs($0 - 77.75) < 1e-6 } == true,
          "…and suggests exactly where cut_speech cuts, 77.75 (it said 77.717: the threshold came from the piece ±1 s), got \(tail.suggestedSource ?? -1)")
}

/// 同一份数据，cut_speech 按片段在时间线上的秒问（1.5 倍速、放在时间线 10 秒上）、剪辑点检查按源秒问：每一刻判得一样、挪到同一处。
private func checkHearingAxes() {
    let hearing = AISpeechHearing(levels: l16Levels(), transcript: l16Transcript)
    var clip = videoClip(10, 4, asset: 162.25, sourceStart: 75.5)
    clip.speed = 1.5
    let bySource = hearing.points(silenceDB: nil)
    let byTimeline = hearing.points(silenceDB: nil, clip: clip)
    for time in [75.6, 76.0, 76.9, 77.2, 77.417, 77.5, 77.7, 78.1, 78.6] {
        for side in [AISpeechCutPoints.Side.start, .end] {
            let source = bySource.point(time, side)
            let timeline = byTimeline.point(clip.timelineTime(atSource: time), side)
            let back = clip.sourceTime(atTimeline: timeline.time)
            check(abs(back - source.time) < 1e-9 && (timeline.why == nil) == (source.why == nil) && timeline.onSpeech == source.onSpeech,
                  "\(time) \(side): asked in timeline seconds of a 1.5x clip it lands where the source-seconds judge lands (\(back) vs \(source.time))")
        }
    }
    // 写给 AI 的停顿是问的那条轴上的秒：cut_speech 的 moved 里是时间线秒。
    let why = byTimeline.point(clip.timelineTime(atSource: 77.417), .end).why ?? ""
    check(why.contains(String(format: "%.2f", clip.timelineTime(atSource: 77.601))),
          "the pause in cut_speech's reason is in timeline seconds (\(why))")
}

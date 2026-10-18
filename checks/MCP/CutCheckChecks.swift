import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// listen cuts=true 的纯值（AICutCheck，2026-10-16）：V1 每一段的头和尾都是剪辑点、挨着的两段合成一个、跨着转场的带 transition、
// 开着缝的各报各的、from / to 只留落在里面的；每一头在它声音的源时间轴上判：在停顿里不动、在声音上报切到的词和建议的入出点
// （换回这一段自己的源时间 —— 声音从链接的那段来时两条轴不一样）；写给 AI 的键。判法本身在 SpeechCutPointChecks。
// 方案：docs/plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md。编法见 scripts/check-mcp.sh。

func runCutCheckChecks() {
    checkCutBoundaries()
    checkCutSides()
    checkCutQuietSpot()
    checkCutDipInWordTail()
    checkCutLinkedSound()
    checkCutJSON()
}

private func checkCutBoundaries() {
    let a = videoClip(0, 4), b = videoClip(4, 3, sourceStart: 10), c = videoClip(7, 5, sourceStart: 20)
    let edges = AICutCheck.boundaries(of: [a, b, c])
    checkEqual(edges.map(\.at), [0, 4, 7, 12], "three clips end to end: the first head, two cuts, the last tail")
    checkEqual(edges.map { $0.outgoing?.id }, [nil, a.id, b.id, c.id], "…each point names the clip going out")
    checkEqual(edges.map { $0.incoming?.id }, [a.id, b.id, c.id, nil], "…and the clip coming in")
    check(edges.allSatisfy { $0.transition == nil }, "hard cuts have no transition")
    checkEqual(AICutCheck.boundaries(of: [c, a, b]).map(\.at), [0, 4, 7, 12], "clips are taken in timeline order")

    let gapped = AICutCheck.boundaries(of: [videoClip(0, 4), videoClip(5, 3)])
    checkEqual(gapped.map(\.at), [0, 4, 5, 8], "a gap: the tail before it and the head after it are two separate points")
    check(gapped[1].incoming == nil && gapped[2].outgoing == nil, "…each with one side only")
    checkEqual(AICutCheck.boundaries(of: [videoClip(0, 4), videoClip(4.005, 3)]).count, 3, "a 5 ms gap is still one cut (mainGapTolerance)")

    var first = videoClip(0, 4)
    first.transitionAfter = .crossFade
    first.transitionDuration = 0.5
    let crossed = AICutCheck.boundaries(of: [first, videoClip(3.5, 3)])
    checkEqual(crossed.map(\.at), [0, 3.5, 6.5], "a transition: the cut is where the pictures start to mix")
    check(crossed[1].transition.map { abs($0 - 0.5) < 1e-9 } == true, "…and says how long they overlap (got \(crossed[1].transition ?? -1))")
    check(crossed[1].outgoing?.id == first.id && crossed[1].incoming != nil, "…with both sides")

    checkEqual(AICutCheck.boundaries(of: [a, b, c], from: 3, to: 8).map(\.at), [4, 7], "from/to keep only the cuts inside")
    checkEqual(AICutCheck.boundaries(of: [a, b, c], from: 4, to: nil).map(\.at), [4, 7, 12], "a cut exactly at from counts")
}

// MARK: 判一头：「…work. When I got」，声音 40–41.48 响、41.48–41.96 停、41.96–42.48 响（同 SpeechCutPointChecks 的样本）

private func cutWord(_ text: String, _ start: Double, _ end: Double) -> SpeechTranscript.Word {
    SpeechTranscript.Word(text: text, start: start, end: end, sourceStart: start, sourceEnd: end, confidence: nil)
}

/// 每 0.04 秒一个窗，`loud` 里的 −20 dB、其余 −60 dB（门限 −40 时就是停顿）。
private func cutLevels(from: Double, to: Double, loud: [ClosedRange<Double>]) -> [AIAudioLevels.Window] {
    let count = Int(((to - from) / 0.04).rounded())
    return (0..<count).map { index in
        let start = from + Double(index) * 0.04
        let end = from + Double(index + 1) * 0.04
        let isLoud = loud.contains { $0.contains((start + end) / 2) }
        return AIAudioLevels.Window(start: start, end: end, meanSquare: isLoud ? 0.01 : 0.000_001, peak: isLoud ? 0.3 : 0.001)
    }
}

private let whenWords = [cutWord("work.", 40.6, 41.2), cutWord("When", 41.7, 42.05), cutWord("I", 42.2, 42.3), cutWord("got", 42.4, 42.7)]
private let whenPoints = AISpeechCutPoints(
    words: whenWords, levels: cutLevels(from: 40, to: 43.2, loud: [40...41.48, 41.96...42.48, 42.56...42.88]), silenceDB: -40
)

private func checkCutSides() {
    // 头切在停顿里（源 41.917），这一段放在时间线 10 秒上。
    let clip = videoClip(10, 2, sourceStart: 41.917)
    let head = AICutCheck.side(of: clip, end: .start, at: 10, sound: clip, points: whenPoints)
    checkEqual(head.verdict, .inPause, "a head in the measured pause: in_pause")
    check(head.suggestedSource == nil && head.suggestedAt == nil, "…suggests nothing")

    // 头切进「When I」里（源 42.1：转写的两个词之间、声音上正在说话）。
    let late = videoClip(10, 2, sourceStart: 42.1)
    let onWord = AICutCheck.side(of: late, end: .start, at: 10, sound: late, points: whenPoints)
    guard case .onSpeech(let word, let why) = onWord.verdict else { return check(false, "a head on speech: on_speech, got \(onWord.verdict)") }
    checkEqual(word, "When", "…names the word it cuts into (the nearest one when the transcript has a gap there)")
    check(why.contains("pause"), "…and says where the cut would go (\(why))")
    check(onWord.suggestedSource.map { $0 > 41.48 && $0 < 41.96 } == true,
          "…suggested source_in is inside the real pause (got \(onWord.suggestedSource ?? -1))")
    check(onWord.suggestedAt.map { suggestedAt in
        onWord.suggestedSource.map { abs(suggestedAt - (10 + $0 - 42.1)) < 1e-9 } == true
    } == true, "…and the timeline time is the same moment (got \(onWord.suggestedAt ?? -1))")

    // 尾切在「work.」的尾音上（源 41.2，声音说到 41.48）：挪进停顿的中间。
    let tail = videoClip(0, 1.2, sourceStart: 40)
    let onTail = AICutCheck.side(of: tail, end: .end, at: 1.2, sound: tail, points: whenPoints)
    guard case .onSpeech(let tailWord, _) = onTail.verdict else { return check(false, "a tail on the end of a word: on_speech") }
    checkEqual(tailWord, "work.", "…names the word")
    check(onTail.suggestedSource.map { abs($0 - 41.72) < 1e-6 } == true,
          "…suggested source_out is the middle of the pause (41.72, got \(onTail.suggestedSource ?? -1))")

    // 一口气说到素材结尾、附近没有停顿：报在声音上，不编一个建议。
    let busy = AISpeechCutPoints(
        words: [cutWord("end", 59.0, 59.9)], levels: cutLevels(from: 58, to: 60, loud: [58...60]), silenceDB: -40
    )
    let noPause = AICutCheck.side(of: videoClip(0, 1.95, sourceStart: 58), end: .end, at: 1.95, sound: videoClip(0, 1.95, sourceStart: 58), points: busy)
    guard case .onSpeech(let busyWord, let busyWhy) = noPause.verdict else { return check(false, "no pause anywhere: still on_speech") }
    checkEqual(busyWord, "end", "…the word is the nearest one within 0.3 s")
    check(busyWhy.contains("no pause"), "…and the reason says there is no pause (\(busyWhy))")
    check(noPause.suggestedSource == nil, "…with no suggestion to offer")

    // 没有转写：照样判停顿，词是 nil。
    let soundOnly = AISpeechCutPoints(
        words: [], levels: cutLevels(from: 40, to: 43.2, loud: [40...41.48, 41.96...42.48]), silenceDB: -40
    )
    let noWords = AICutCheck.side(of: late, end: .start, at: 10, sound: late, points: soundOnly)
    guard case .onSpeech(let none, _) = noWords.verdict else { return check(false, "without a transcript a head on sound is on_speech") }
    check(none == nil, "…and names no word")
    check(noWords.suggestedSource.map { $0 > 41.48 && $0 < 41.96 } == true, "…but still suggests the pause (got \(noWords.suggestedSource ?? -1))")
}

/// 两个词连着说、中间只有一个安静窗（0.04 秒，不到一个停顿）：切在词上时建议挪进那一格；照建议改完再查，那一格是 quiet_spot ——
/// 不叫词、不再建议。2026-10-16 测试版冒烟：第一版把自己建议的那一格又报成 on_speech（词是「custom」）、还给不出更好的地方
///（docs/bugfixes/2026-10-16-listen-cuts-suggested-spot-reported-on-speech.md）。真的停顿在够得着的地方时，安静窗里的切口照样建议挪进停顿。
private func checkCutQuietSpot() {
    let words = [cutWord("custom", 38.10, 38.64), cutWord("AI", 38.64, 39.30)]
    // 响到 38.46、38.46–38.50 一格安静、38.50 起又响（窗从 37.5 起每 0.04 秒一个）。
    let points = AISpeechCutPoints(words: words, levels: cutLevels(from: 37.5, to: 40, loud: [37.5...38.45, 38.51...40]), silenceDB: -40)
    check(points.pauses?.isEmpty == true && points.quiet.count == 1, "the sample has one quiet window and no pause (got \(points.quiet))")
    let clip = videoClip(0, 2.5, sourceStart: 37.5)
    let onWord = AICutCheck.side(of: clip, end: .start, at: 38.9 - 37.5, sound: clip, points: points)
    guard case .onSpeech(let word, let why) = onWord.verdict else { return check(false, "a head on 'AI' with no pause around: on_speech, got \(onWord.verdict)") }
    checkEqual(word, "AI", "…names the word")
    check(why.contains("quiet spot"), "…and says it moved to the quiet spot (\(why))")
    check(onWord.suggestedSource.map { $0 > 38.45 && $0 < 38.51 } == true, "…suggested source_in is that quiet window (got \(onWord.suggestedSource ?? -1))")
    guard let suggestedAt = onWord.suggestedAt else { return check(false, "…with a timeline moment") }
    let moved = AICutCheck.side(of: clip, end: .start, at: suggestedAt, sound: clip, points: points)
    checkEqual(moved.verdict, .quietSpot, "cut where it suggested, the head checks back as quiet_spot (not on_speech)")
    check(moved.suggestedSource == nil && moved.suggestedAt == nil, "…and nothing further is suggested")
    checkEqual(AICutCheck.side(of: clip, end: .end, at: suggestedAt, sound: clip, points: points).verdict, .quietSpot, "…the tail side too")
    // 安静窗旁边够得着一个真的停顿：cut_speech 会挪进停顿，所以不是 quiet_spot（2026-10-16 的第一版这里报 quiet_spot ——「cut_speech 也会
    // 切在这」—— 同时又建议挪进停顿，自相矛盾；docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。
    let withPause = AISpeechCutPoints(
        words: words, levels: cutLevels(from: 37.5, to: 40, loud: [37.5...38.45, 38.51...38.80, 39.20...40]), silenceDB: -40
    )
    let better = AICutCheck.side(of: clip, end: .start, at: suggestedAt, sound: clip, points: withPause)
    guard case .onSpeech = better.verdict else {
        return check(false, "a lone quiet window with a real pause within reach: on_speech like cut_speech, got \(better.verdict)")
    }
    check(better.suggestedSource.map { $0 > 38.80 && $0 < 39.20 } == true, "…pointing at the real pause (got \(better.suggestedSource ?? -1))")
    let cutSpeech = withPause.point(clip.sourceTime(atTimeline: suggestedAt), .start).time
    check(better.suggestedSource.map { abs($0 - cutSpeech) < 1e-9 } == true,
          "…exactly where cut_speech would cut (\(cutSpeech), got \(better.suggestedSource ?? -1))")
}

/// L16（2026-10-18 测试员）：「available.」的尾音里有一格 46 ms 的低谷（−48 dB），之后尾音又响了 0.1 秒，真停顿才开始；剪在低谷上
///（77.417）。cut_speech 说这一刀在声音上、挪进停顿；检查以前说 quiet_spot（「可以不改、cut_speech 也会切在这」）同时又建议挪进停顿，
/// 切到的词还会认成停顿后面的「The」。这里照那一刻的形状造：每 0.04 秒一个窗，−40 dB 的门限下 77.40–77.44 是低谷、77.56–77.88 是停顿。
private func checkCutDipInWordTail() {
    // 「The」估过的开口（77.56，停顿后第一个词宁早勿晚）已经在尾音里；「available.」照识别器收在 77.16。
    let words = [cutWord("currently", 76.02, 76.44), cutWord("available.", 76.44, 77.16), cutWord("The", 77.56, 77.94), cutWord("aspect", 77.94, 78.3)]
    let points = AISpeechCutPoints(
        words: words, levels: cutLevels(from: 76, to: 78.4, loud: [76...77.40, 77.44...77.56, 77.88...78.4]), silenceDB: -40
    )
    // 剪完的那一段：源 1715–1858 帧（71.458–77.417），放在时间线 417 帧（17.375）上 —— 都在 24 fps 的格子上，同 cut_speech 剪出来的。
    let frame = 1.0 / 24
    let piece = videoClip(417 * frame, (1858 - 1715) * frame, asset: 162.25, sourceStart: 1715 * frame)
    check(points.pauses?.count == 1 && points.quiet.contains { $0.contains(1858 * frame) },
          "the sample: one pause (77.56–77.88) and a lone quiet window over 77.417 (got \(points.pauses ?? []))")
    let tail = AICutCheck.side(of: piece, end: .end, at: piece.timelineEnd, sound: piece, points: points, frame: frame)
    guard case .onSpeech(let word, let why) = tail.verdict else {
        return check(false, "a tail in a dip inside the last word, with the pause 0.14 s on: on_speech (cut_speech moves it), got \(tail.verdict)")
    }
    checkEqual(word, "available.", "…the word it cuts is the one still sounding, not 'The' after the pause")
    check(why.contains("pause"), "…and it says where cut_speech would cut (\(why))")
    let cutSpeech = AISpeechCuts.onFrame(points.point(1858 * frame, .end).time, frame: frame)
    check(tail.suggestedSource.map { abs($0 - cutSpeech) < 1e-6 } == true,
          "…suggested source_out is where cut_speech cuts, on a frame (\(cutSpeech), got \(tail.suggestedSource ?? -1))")
    guard let suggestedAt = tail.suggestedAt else { return check(false, "…with a timeline moment") }
    let moved = videoClip(piece.timelineStart, suggestedAt - piece.timelineStart, asset: 162.25, sourceStart: piece.sourceStart)
    checkEqual(AICutCheck.side(of: moved, end: .end, at: moved.timelineEnd, sound: moved, points: points, frame: frame).verdict, .inPause,
               "cut where it suggested, the tail checks back as in_pause")
}

/// 画面静音、声音在链接的音频段上，两段的源时间轴不一样：判在声音那条轴上，建议换回画面这一段的源时间。
private func checkCutLinkedSound() {
    var video = videoClip(10, 2, sourceStart: 5)
    video.isMuted = true
    var audio = audioClip(10, 2)
    audio.sourceStart = 42.1
    let side = AICutCheck.side(of: video, end: .start, at: 10, sound: audio, points: whenPoints)
    guard case .onSpeech(let word, _) = side.verdict else { return check(false, "judged on the linked sound: on_speech") }
    checkEqual(word, "When", "…the word comes from the sound clip's transcript")
    check(side.suggestedAt.map { abs($0 - (10 + 41.72 - 42.1)) < 1e-9 } == true, "…the timeline moment is where the audio's pause is (got \(side.suggestedAt ?? -1))")
    check(side.suggestedSource.map { abs($0 - (5 + 41.72 - 42.1)) < 1e-9 } == true,
          "…and source_in is the video clip's own source time there (got \(side.suggestedSource ?? -1))")
}

private func checkCutJSON() {
    var state = TimelineState()
    let a = videoClip(0, 4), b = videoClip(4, 3, sourceStart: 10)
    state.mainClips = [a, b]
    let ids = AIShortIDs(state: state)
    let edges = [AICutCheck.Edge(
        at: 4,
        outgoing: AICutCheck.Side(clipID: a.id, end: .end, at: 4, verdict: .inPause),
        incoming: AICutCheck.Side(
            clipID: b.id, end: .start, at: 4, verdict: .onSpeech(word: "When", why: "on speech: moved into the pause 9.5–9.9 s"),
            suggestedSource: 9.7, suggestedAt: 3.7
        ),
        transition: 0.5
    )]
    let cut = AICutCheck.json(edges, ids: ids).first
    checkEqual(cut?["at"]?.doubleValue, 4, "a cut: at")
    checkEqual(cut?["transition"]?.doubleValue, 0.5, "…transition")
    checkEqual(cut?["out"]?["status"]?.stringValue, "in_pause", "…the outgoing side's status")
    checkEqual(cut?["out"]?["clip"]?.stringValue, ids.short(a.id), "…and clip")
    check(cut?["out"]?["suggested_source_out"] == nil && cut?["out"]?["word"] == nil, "a side in a pause has no word and no suggestion")
    checkEqual(cut?["in"]?["status"]?.stringValue, "on_speech", "…the incoming side")
    checkEqual(cut?["in"]?["word"]?.stringValue, "When", "…the word")
    checkEqual(cut?["in"]?["suggested_source_in"]?.doubleValue, 9.7, "…the suggestion as that clip's source_in")
    checkEqual(cut?["in"]?["suggested_at"]?.doubleValue, 3.7, "…and on the timeline")
    check(cut?["in"]?["why"]?.stringValue?.contains("pause") == true, "…with the reason")
    checkEqual(AICutCheck.onSpeechCount(edges), 1, "one side on speech")
    let hardCut = AICutCheck.json([AICutCheck.Edge(at: 7, incoming: AICutCheck.Side(clipID: b.id, end: .start, at: 7, verdict: .inPause))], ids: ids).first
    check(hardCut?["transition"] == nil && hardCut?["out"] == nil, "a head alone: no transition, no out side")
    let quiet = AICutCheck.json(AICutCheck.Side(clipID: a.id, end: .end, at: 4, verdict: .quietSpot), ids: ids)
    checkEqual(quiet["status"]?.stringValue, "quiet_spot", "a side in the quietest spot between words")
    check(quiet["why"]?.stringValue?.contains("quietest") == true && quiet["word"] == nil, "…says why and names no word")
    checkEqual(AICutCheck.onSpeechCount([AICutCheck.Edge(at: 4, outgoing: AICutCheck.Side(clipID: a.id, end: .end, at: 4, verdict: .quietSpot))]), 0,
               "a quiet spot does not count as on speech")
    let unheard = AICutCheck.json(AICutCheck.Side(clipID: a.id, end: .end, at: 4, verdict: .unheard("muted: nothing to hear at this cut")), ids: ids)
    checkEqual(unheard["status"]?.stringValue, "unheard", "a side that could not be heard")
    check(unheard["note"]?.stringValue?.hasPrefix("muted") == true, "…says why")
}

import Foundation
import SrtFlowCore

// 第 1h 组：字幕句两头各自跟着画面换算（联动规矩 12，`LinkageCueFollow`，2026-10-15）。
//
// 用户转来的反馈：AI 用 cut_speech 只留几句剪 30 秒版，剪掉的两句字幕只因为尾巴蹭进保留段几帧就整句留了下来；之后 edit_clip 改入点
//（ripple），有一句字幕的开头跑到了片段开始之前。以前字幕整句平移、时长不变；现在两头各自换算（剪掉的收掉、变速跟着伸缩、词的时间一起换），
// 说话的那几秒剩不到一半就删（真删）或留在原地、报出来（裁切）；按说话的那几秒算，不按显示时间（删停顿剪掉的正是「说完多停的半秒」）。
// 案例：docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md。编法见 scripts/check-timeline-snap.sh。

private let talkFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/talk.mp4")
private let otherFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/other.mp4")

private func clip(_ url: URL, at start: Double, duration: Double, sourceStart: Double = 0) -> EditClip {
    var clip = EditClip(sourceURL: url, sourceDuration: duration, timelineStart: start)
    clip.sourceStart = sourceStart
    return clip
}

/// 一句字幕：`speech` 是说话的那几秒（时间线），按它造一个词（相对开头的秒）；nil = 没有逐词时间。
private func cue(_ start: Double, _ end: Double, _ text: String, speech: (Double, Double)? = nil) -> SubtitleCue {
    let words = speech.map { [SubtitleCueWord(location: 0, length: (text as NSString).length, start: $0.0 - start, end: $0.1 - start)] }
    return SubtitleCue(start: start, end: end, text: text, words: words)
}

private func state(main: [EditClip], cues: [SubtitleCue], translation: [SubtitleCue] = [], links: [UUID: TranslationLink] = [:]) -> TimelineState {
    var state = TimelineState()
    state.mainClips = main
    var original = SubtitleDocumentModel(format: .srt)
    original.cues = cues
    state.subtitle = original
    var companion = SubtitleCompanion(origin: .generated)
    if !translation.isEmpty {
        var doc = SubtitleDocumentModel(format: .srt)
        doc.cues = translation
        companion.translation = doc
    }
    companion.translationLinks = links
    state.subtitleCompanion = companion
    return state
}

/// 只留 V1 唯一那段里的几截（cut_speech keep 落账的那一套：切开、删掉其余的、后面的往前补）。
private func keepOnly(_ ranges: [ClosedRange<Double>], of id: UUID, in state: inout TimelineState) {
    for time in ranges.flatMap({ [$0.upperBound, $0.lowerBound] }).sorted(by: >) {
        LinkRegrouping.split([id], at: time, in: &state)
    }
    for piece in state.mainClips where !ranges.contains(where: { abs($0.lowerBound - piece.timelineStart) < 1e-9 }) {
        state.remove(piece.id)
    }
    state.packMain()
}

/// 剪掉 V1 唯一那段里的几截（删停顿、口头禅）。
private func cutOut(_ ranges: [ClosedRange<Double>], of id: UUID, in state: inout TimelineState) {
    for time in ranges.flatMap({ [$0.upperBound, $0.lowerBound] }).sorted(by: >) {
        LinkRegrouping.split([id], at: time, in: &state)
    }
    for piece in state.mainClips where ranges.contains(where: { abs($0.lowerBound - piece.timelineStart) < 1e-9 }) {
        state.remove(piece.id)
    }
    state.packMain()
}

private func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-6 } ?? false }

private func span(_ state: TimelineState, _ id: UUID) -> (start: Double, end: Double)? {
    state.subtitleCue(id).map { ($0.start, $0.end) }
}

func checkLinkageCues() {
    checkKeepOnlyASentenceOrTwo()
    checkShortenedPauses()
    checkInPointTrim()
    checkSpeedAndFreeze()
}

// MARK: - 只留几句（用户的 30 秒版）

private func checkKeepOnlyASentenceOrTwo() {
    let talk = clip(talkFile, at: 0, duration: 60)
    // 剪掉的那句说到 12.5，字幕多停到 13.15，蹭进保留段 0.1 秒；保留的那句估早了 0.05 秒开口、多停 0.05 秒。
    let goneBefore = cue(10, 13.15, "removed sentence one", speech: (10, 12.5))
    let keptFirst = cue(13, 15.95, "kept sentence one", speech: (13, 15.6))
    let goneMiddle = cue(27.5, 30.05, "removed sentence two", speech: (27.5, 29.3))
    let keptSecond = cue(29.9, 32.95, "kept sentence two", speech: (29.9, 32.6))
    let before = state(main: [talk], cues: [goneBefore, keptFirst, goneMiddle, keptSecond])
    var after = before
    keepOnly([13.05...15.9, 30...33], of: talk.id, in: &after)
    checkEqual(after.mainClips.map(\.timelineStart).map { ($0 * 1000).rounded() / 1000 }, [0, 2.85], "只留两截：[0,2.85) [2.85,5.85)")
    let report = TimelineLinkage.follow(from: before, to: &after, deletesContent: true)
    check(span(after, goneBefore.id) == nil, "剪掉的那句：尾巴蹭进保留段 0.1 秒，说的话一个字都没留 → 删（以前整句留下、挂在 0 秒）")
    check(span(after, goneMiddle.id) == nil, "中间剪掉的那句同样删（以前整句挪到第一截里、和保留的那句叠在一起）")
    let first = span(after, keptFirst.id)
    check(near(first?.start, 0) && near(first?.end, 2.85), "保留的第一句收到第一截上：[0,2.85)（got \(String(describing: first)))")
    let second = span(after, keptSecond.id)
    check(near(second?.start, 2.85) && near(second?.end, 5.8),
          "保留的第二句从第二截的开头起，不跑到片段开始之前（以前是 2.75）：got \(String(describing: second))")
    checkEqual(report.deleted, 2, "删了两句")
    checkEqual(report.shortenedCues, [keptFirst.id, keptSecond.id], "两句保留的都收短了（报给 AI）")
    let cues = after.subtitleCues(of: .original).sorted { $0.start < $1.start }
    check(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 }, "剩下的字幕互不重叠")
}

// MARK: - 删停顿、口头禅：尾巴被剪掉的那句缩短，不和下一句叠；短句不误删；词的时间一起换

private func checkShortenedPauses() {
    let talk = clip(talkFile, at: 0, duration: 30)
    // 「Right.」说了 0.4 秒，字幕显示到下一句前 2 帧（6.92）；停顿 5.4–7.0 缩短时剪掉 5.525–6.875。
    let right = cue(5, 6.92, "Right", speech: (5, 5.4))
    let next = cue(7, 9, "So here's the thing", speech: (7, 8.8))
    let translated = cue(5, 6.92, "好")                                // 译文：没有词，按它翻自的那句原文判
    let typed = cue(5, 6.92, "typed")                                  // 没有词、没有来源：只能按显示时间判
    let before = state(main: [talk], cues: [right, next], translation: [translated, typed],
                       links: [translated.id: TranslationLink(sourceIDs: [right.id], sourceText: "Right")])
    var after = before
    cutOut([5.525...6.875], of: talk.id, in: &after)
    TimelineLinkage.follow(from: before, to: &after, deletesContent: true)
    let shrunk = span(after, right.id)
    check(near(shrunk?.start, 5) && near(shrunk?.end, 5.57), "「Right.」的尾巴跟着停顿剪短：[5,5.57)（got \(String(describing: shrunk)))")
    check(near(span(after, next.id)?.start, 5.65), "下一句跟着前移 1.35")
    check((shrunk?.end ?? 99) <= (span(after, next.id)?.start ?? 0), "两句不再叠在画面上（以前「Right.」原样到 6.92、和下一句叠 1.27 秒）")
    check(near(span(after, translated.id)?.end, 5.57), "它的译文按原文说话的那几秒判：留下、一起收短")
    check(span(after, typed.id) == nil, "没有词也没有来源的那句只能按显示时间判：剩三成，删（已知不足）")

    // 口头禅在一句中间：剪掉之后，后面的词往前挪、剪掉的词收掉。
    let words = [
        SubtitleCueWord(location: 0, length: 2, start: 0, end: 0.2),     // So
        SubtitleCueWord(location: 3, length: 2, start: 0.35, end: 0.6),  // um（剪掉）
        SubtitleCueWord(location: 6, length: 2, start: 0.9, end: 1.1),   // we
        SubtitleCueWord(location: 9, length: 5, start: 1.2, end: 1.6)    // start
    ]
    let sentence = SubtitleCue(start: 10, end: 12, text: "So um we start", words: words)
    let withFiller = state(main: [talk], cues: [sentence])
    var cut = withFiller
    cutOut([10.3...10.85], of: talk.id, in: &cut)
    TimelineLinkage.follow(from: withFiller, to: &cut, deletesContent: true)
    let moved = cut.subtitleCue(sentence.id)
    check(near(moved?.start, 10) && near(moved?.end, 11.45), "中间剪掉 0.55 秒：这句缩短 0.55（got \(String(describing: moved.map { ($0.start, $0.end) })))")
    let times = moved?.words?.map { [($0.start * 1000).rounded() / 1000, ($0.end * 1000).rounded() / 1000] }
    checkEqual(times, [[0, 0.2], [0.3, 0.3], [0.35, 0.55], [0.65, 1.05]],
               "词的时间跟着换：剪掉的「um」收到切口上，后面的词前移 0.55（逐词高亮还对得上声音）")
}

// MARK: - 改入点（ripple）：跨在裁切点上的那句收到片段开头；大半被裁掉的留在原地、报出来

private func checkInPointTrim() {
    let first = clip(otherFile, at: 0, duration: 8)
    let second = clip(talkFile, at: 8, duration: 7)
    let across = cue(8.2, 9.5, "starts on the trimmed head", speech: (8.2, 9.3))
    let trimmedAway = cue(8, 8.4, "all on the trimmed head", speech: (8, 8.35))
    let mostlyTrimmed = cue(8, 8.6, "mostly on the trimmed head", speech: (8.05, 8.55))
    let before = state(main: [first, second], cues: [trimmedAway, mostlyTrimmed, across])
    var after = before
    after.trim(TimelineTrim.Member(id: second.id, kind: .clip), leading: true, by: 0.5)
    after.packMain()
    checkEqual(after.mainClips.map(\.timelineStart), [0, 8], "改入点 +0.5：第二段还从 8 开始，画面前移 0.5")
    let report = TimelineLinkage.follow(from: before, to: &after, deletesContent: false)
    let moved = span(after, across.id)
    check(near(moved?.start, 8) && near(moved?.end, 9),
          "跨在裁切点上的那句收到片段开头：[8,9)，不跑到片段开始之前（以前是 7.7）：got \(String(describing: moved))")
    check(near(span(after, trimmedAway.id)?.start, 8) && near(span(after, mostlyTrimmed.id)?.end, 8.6),
          "整句在被裁掉那截上的、说的话大半被裁掉的：留在原地（裁切不删）")
    checkEqual(report.leftCues, [trimmedAway.id, mostlyTrimmed.id], "留在原地的报给 AI")
    checkEqual(report.shortenedCues, [across.id], "收短了的也报")
    check(!report.isEmpty, "只有留在原地的也算这次联动有事要报")
}

// MARK: - 变速跟着伸缩；中间插进别的（定格）照老规矩

private func checkSpeedAndFreeze() {
    let talk = clip(talkFile, at: 0, duration: 10)
    let line = cue(2, 4, "two seconds")
    let across = cue(5, 7, "across the freeze point")
    let before = state(main: [talk], cues: [line, across])
    var faster = before
    faster.update(talk.id) { $0.speed = 2 }
    faster.packMain()
    TimelineLinkage.follow(from: before, to: &faster, deletesContent: false)
    let halved = span(faster, line.id)
    check(near(halved?.start, 1) && near(halved?.end, 2), "两倍速：字幕跟着那几帧到 [1,2)，时长也减半（以前时长不变）")

    var frozen = before
    let still = EditClip(
        sourceURL: URL(fileURLWithPath: "/tmp/srtflow-snap-check/still.mp4"), sourceDuration: 2, timelineStart: 6,
        stillImageURL: URL(fileURLWithPath: "/tmp/srtflow-snap-check/still.png")
    )
    frozen.insertFreeze(still, splitting: talk.id, at: 6)
    frozen.packMain()
    TimelineLinkage.follow(from: before, to: &frozen, deletesContent: false)
    let kept = span(frozen, across.id)
    check(near(kept?.start, 5) && near(kept?.end, 7), "中间插进了静帧：照老规矩跟着最早还在的那截画面（不动），不拉长到静帧上")
}

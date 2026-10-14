import Foundation
import SrtFlowCore

// 第 1g 组：生成的字幕句跟着它的那段声音走（`CaptionSourceFollow`，2026-10-14）。
//
// 一句原文字幕记着它是从哪一段生成的（`CueMeta.provenance.clipID`：转写、配音都记）。那段不在主轨上时（配音、音频轨上的采访）：
// 段挪了字幕跟着挪、裁了头字幕留在原地（素材的那一刻没动）、变了速按素材那一刻换算、被真删字幕一起删、别的操作让它没了字幕留着；
// 这次自己改过的句子不碰；来源在主轨上的句子照旧只跟画面（老规矩），不被这条再挪一次。
// 由来：2026-10-06 盲测，AI 挪了配音段，字幕留在原地（docs/bugfixes/2026-10-14-voiceover-subtitles-stay-behind.md）。

private let voiceFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/voiceover.m4a")
private let footage = URL(fileURLWithPath: "/tmp/srtflow-snap-check/main.mp4")

/// 主轨一段 [0,30)；A1 上一段配音 [10,14)（素材 0–4 秒）带两句字幕 [10.2,11.8)、[12,13.6)；主轨来源的一句 [3,5)；一句手打的 [20,21)。
private struct CaptionFixture {
    var state = TimelineState()
    let main = EditClip(sourceURL: footage, sourceDuration: 30, timelineStart: 0)
    let voice = EditClip(sourceURL: voiceFile, isAudioOnly: true, sourceDuration: 4, timelineStart: 10)
    let first = SubtitleCue(start: 10.2, end: 11.8, text: "first line")
    let second = SubtitleCue(start: 12, end: 13.6, text: "second line")
    let fromMain = SubtitleCue(start: 3, end: 5, text: "spoken on V1")
    let typed = SubtitleCue(start: 20, end: 21, text: "typed by hand")

    init() {
        state.mainClips = [main]
        state.audioTracks = [EditLane(clips: [voice])]
        var original = SubtitleDocumentModel(format: .srt)
        original.cues = [fromMain, first, second, typed]
        state.subtitle = original
        var companion = SubtitleCompanion(origin: .generated)
        companion.cueMeta[first.id] = CueMeta(provenance: CueProvenance(clipID: voice.id))
        companion.cueMeta[second.id] = CueMeta(provenance: CueProvenance(clipID: voice.id))
        companion.cueMeta[fromMain.id] = CueMeta(provenance: CueProvenance(clipID: main.id))
        state.subtitleCompanion = companion
    }
}

private func cueStart(_ state: TimelineState, _ id: UUID) -> Double? {
    state.subtitleCues(of: .original).first { $0.id == id }.map { ($0.start * 1000).rounded() / 1000 }
}

func checkLinkageCaptions() {
    // 挪配音段 +3 秒：两句跟着 +3，主轨来源的、手打的不动。
    let base = CaptionFixture()
    var moved = base.state
    moved.update(base.voice.id) { $0.timelineStart = 13 }
    let report = TimelineLinkage.follow(from: base.state, to: &moved, deletesContent: false)
    checkEqual(cueStart(moved, base.first.id), 13.2, "a voiceover clip moved +3 s: its first subtitle follows")
    checkEqual(cueStart(moved, base.second.id), 15, "…and its second")
    checkEqual(cueStart(moved, base.fromMain.id), 3, "a subtitle generated from V1 is left to the picture rule")
    checkEqual(cueStart(moved, base.typed.id), 20, "a typed subtitle without a source stays")
    checkEqual(report.moved, 2, "the report counts the two subtitles that followed")
    checkEqual(moved.subtitleCues(of: .original).first { $0.id == base.first.id }.map { ($0.end * 1000).rounded() / 1000 }, 14.8,
               "the subtitle keeps its length")

    // 裁掉配音的头 1 秒（起点也后移 1 秒，素材那一刻没动）：字幕留在原地。
    var trimmed = base.state
    trimmed.update(base.voice.id) { $0.sourceStart = 1; $0.sourceDuration = 3; $0.timelineStart = 11 }
    TimelineLinkage.follow(from: base.state, to: &trimmed, deletesContent: false)
    checkEqual(cueStart(trimmed, base.second.id), 12, "trimming the head keeps the subtitles where the words are")

    // 变成 2 倍速：素材第 2 秒（第二句的开头）落在段起点后 1 秒。
    var faster = base.state
    faster.update(base.voice.id) { $0.speed = 2 }
    TimelineLinkage.follow(from: base.state, to: &faster, deletesContent: false)
    checkEqual(cueStart(faster, base.second.id), 11, "a speed change maps the subtitle through the source time")

    // 真删配音段：两句一起删；不是真删的操作让它没了：字幕留着。
    var deleted = base.state
    deleted.remove(base.voice.id)
    TimelineLinkage.follow(from: base.state, to: &deleted, deletesContent: true)
    check(cueStart(deleted, base.first.id) == nil && cueStart(deleted, base.second.id) == nil,
          "deleting the voiceover deletes its subtitles")
    checkEqual(cueStart(deleted, base.typed.id), 20, "…but not the others")
    var gone = base.state
    gone.remove(base.voice.id)
    TimelineLinkage.follow(from: base.state, to: &gone, deletesContent: false)
    checkEqual(cueStart(gone, base.first.id), 10.2, "without a real delete the subtitles stay")

    // 这次操作自己挪过的句子不碰（AI 一边挪段、一边把第一句挪到 30 秒）。
    var both = base.state
    both.update(base.voice.id) { $0.timelineStart = 13 }
    both.editSubtitleTracks { original, companion in
        SubtitleTrackEditing.setStarts([base.first.id: 30], original: &original, companion: &companion)
    }
    TimelineLinkage.follow(from: base.state, to: &both, deletesContent: false)
    checkEqual(cueStart(both, base.first.id), 30, "a subtitle this edit moved itself is not moved again")
    checkEqual(cueStart(both, base.second.id), 15, "the untouched one still follows")
}

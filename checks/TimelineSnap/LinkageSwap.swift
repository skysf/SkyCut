import Foundation
import SrtFlowCore

// 第 1i 组：同 id 的段换了素材（upscale 换源 `ClipSourceSwap.apply`、edit_clip 换文件 `ClipFileReplacement`）时，联动不动任何东西。
//
// 换源 = 源时间整体平移、时间线上的位置和长度不动（docs/architecture/video-edit-project-file.md「四之五」）：画面账按「这段现在摆的地方，
// 画面就是改之前这段的画面」记 —— 压在上面的字幕、文字、音效、形状、滤镜、B-roll 都原地不动、一样不删，字幕说话的那几秒也不变；
// 换文件的同时挪了段，压在上面的东西跟着段挪、相对位置不变。配音段（规矩 11）换了声音文件同样不挪它的字幕。
// 由来：2026-10-15 做「裁切让字幕说的话剩不到一半就删」之前先验的风险：同 id 的段以前按源时间对账、不看素材，upscale 文件从原片
// 第 4 秒起时压在上面的东西全被挪了 4 秒（docs/bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md）。

private let original = URL(fileURLWithPath: "/tmp/srtflow-snap-check/shot.mp4")
private let upscaled = URL(fileURLWithPath: "/tmp/srtflow-snap-check/shot_1920x1080_topaz-precision.mp4")
private let otherTake = URL(fileURLWithPath: "/tmp/srtflow-snap-check/other-take.mp4")
private let footage = URL(fileURLWithPath: "/tmp/srtflow-snap-check/b.mp4")
private let broll = URL(fileURLWithPath: "/tmp/srtflow-snap-check/c.mp4")
private let sfxFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/music.m4a")
private let voiceFile = URL(fileURLWithPath: "/tmp/srtflow-snap-check/voiceover.m4a")
private let otherVoice = URL(fileURLWithPath: "/tmp/srtflow-snap-check/voiceover-take2.m4a")

private func info(duration: Double) -> MediaInfo {
    MediaInfo(
        duration: duration, displaySize: CGSize(width: 1920, height: 1080), frameRate: 24, videoCodec: "avc1", audioCodec: "aac",
        hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1_000, keyframeInterval: nil
    )
}

/// 主轨 A [0,10) 用原片的 5–15 秒、B [10,20)；A 上压着一句字幕（词 2.1–3.8）、文字、音效、形状、滤镜、B-roll；配乐铺整片。
private struct SwapFixture {
    var state = TimelineState()
    let a = EditClip(sourceURL: original, sourceStart: 5, sourceDuration: 10, timelineStart: 0, info: info(duration: 20))
    let b = EditClip(sourceURL: footage, sourceDuration: 10, timelineStart: 10)
    let cue = SubtitleCue(start: 2, end: 4, text: "on the swapped clip",
                          words: [SubtitleCueWord(location: 0, length: 19, start: 0.1, end: 1.8)])
    let text = TextOverlay(text: "title", timelineStart: 1, duration: 2)
    let sfx = EditClip(sourceURL: sfxFile, isAudioOnly: true, sourceDuration: 1, timelineStart: 3)
    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 2, duration: 2)
    let filter = FilterClip(preset: .tealOrange, timelineStart: 1, duration: 4)
    let roll = EditClip(sourceURL: broll, sourceDuration: 3, timelineStart: 5)
    let music = EditClip(sourceURL: sfxFile, isAudioOnly: true, sourceDuration: 20, timelineStart: 0)

    init() {
        state.mainClips = [a, b]
        state.overlayTracks = [EditLane(clips: [roll])]
        state.audioTracks = [EditLane(clips: [sfx]), EditLane(clips: [music])]
        var document = SubtitleDocumentModel(format: .srt)
        document.cues = [cue]
        state.subtitle = document
        state.textOverlays = [text]
        state.shapes = [shape]
        state.filters = [filter]
    }

    /// 压在 A 上的每一样东西的起点（字幕带结尾和词的开头）。
    func positions(_ state: TimelineState) -> [String: Double?] {
        [
            "cue.start": state.subtitleCue(cue.id)?.start, "cue.end": state.subtitleCue(cue.id)?.end,
            "cue.word": state.subtitleCue(cue.id)?.words?.first?.start,
            "text": state.textOverlays.first { $0.id == text.id }?.timelineStart,
            "sfx": state.clip(with: sfx.id)?.timelineStart, "shape": state.shapes.first { $0.id == shape.id }?.timelineStart,
            "filter": state.filters.first { $0.id == filter.id }?.timelineStart, "roll": state.clip(with: roll.id)?.timelineStart,
            "music": state.clip(with: music.id)?.timelineStart,
        ]
    }
}

func checkLinkageSwap() {
    let f = SwapFixture()
    let before = f.state
    let untouched = f.positions(before)

    // ---- upscale 换源：新文件是原片的 4–16 秒（带 1 秒余料），入点 5 → 1，源时间整体平移 4 ----
    var swapped = before
    let record = ClipUpscaleRecord(originalURL: original, sourceOffset: 4, tier: "topaz-precision")
    let replacement = ClipSourceSwap.Replacement(url: upscaled, info: info(duration: 12), record: record)
    checkEqual(swapped.applyUpscale(replacement, to: [f.a.id]), [f.a.id], "换源：范围被盖住，换了")
    checkClose(swapped.clip(with: f.a.id)?.sourceStart ?? -1, 1, "入点 5 → 新文件里的 1（源时间平移 4）")
    let report = TimelineLinkage.follow(from: before, to: &swapped, deletesContent: false)
    check(report.isEmpty, "换源之后联动什么都不动、不删（got \(report)）")
    checkEqual(f.positions(swapped), untouched, "压在换源那段上的字幕、文字、音效、形状、滤镜、B-roll、配乐都原地不动")

    // ---- edit_clip 换文件：读另一个文件、从它的第 3 秒起（ClipFileReplacement 的两步：入点平移 + 换 url）----
    var replaced = before
    replaced.update(f.a.id) { clip in
        ClipSourceSwap.shift(&clip, by: 3 - clip.sourceStart)
        clip.sourceStart = 3
        clip.sourceURL = otherTake
    }
    TimelineLinkage.follow(from: before, to: &replaced, deletesContent: false)
    checkEqual(f.positions(replaced), untouched, "换成另一个文件：压在上面的东西原地不动、不删")

    // ---- 换文件的同时把 A 挪到 B 后面（edit_clip file + start）：压在 A 上的东西跟着 A 挪 10，相对位置不变 ----
    var movedToo = before
    movedToo.update(f.a.id) { clip in
        ClipSourceSwap.shift(&clip, by: 3 - clip.sourceStart)
        clip.sourceStart = 3
        clip.sourceURL = otherTake
        clip.timelineStart = 20
    }
    movedToo.sortMainClipsByStart()
    movedToo.packMain()   // B [0,10) A [10,20)
    TimelineLinkage.follow(from: before, to: &movedToo, deletesContent: false)
    let shifted = f.positions(movedToo)
    checkEqual(shifted["cue.start"] ?? nil, 12, "换文件又挪了段：字幕跟着段挪 10")
    checkEqual(shifted["cue.end"] ?? nil, 14, "…结尾也挪 10、时长不变")
    checkEqual(shifted["cue.word"] ?? nil, 0.1, "…词的时间（相对开头）不变")
    checkEqual(shifted["text"] ?? nil, 11, "文字跟着挪 10")
    checkEqual(shifted["sfx"] ?? nil, 13, "音效跟着挪 10")
    checkEqual(shifted["shape"] ?? nil, 12, "形状跟着挪 10")
    checkEqual(shifted["filter"] ?? nil, 11, "滤镜跟着挪 10")
    checkEqual(shifted["roll"] ?? nil, 15, "B-roll 跟着挪 10")
    checkEqual(shifted["music"] ?? nil, 0, "铺整片的配乐：两段各挪各的，不动")

    // ---- 配音段（规矩 11）换成另一个声音文件、从它的第 2 秒起：它的字幕不挪 ----
    var voiced = TimelineState()
    let main = EditClip(sourceURL: footage, sourceDuration: 30, timelineStart: 0)
    let voice = EditClip(sourceURL: voiceFile, isAudioOnly: true, sourceDuration: 4, timelineStart: 10)
    let line = SubtitleCue(start: 10.2, end: 11.8, text: "narration")
    voiced.mainClips = [main]
    voiced.audioTracks = [EditLane(clips: [voice])]
    var narration = SubtitleDocumentModel(format: .srt)
    narration.cues = [line]
    voiced.subtitle = narration
    var companion = SubtitleCompanion(origin: .generated)
    companion.cueMeta[line.id] = CueMeta(provenance: CueProvenance(clipID: voice.id))
    voiced.subtitleCompanion = companion
    var revoiced = voiced
    revoiced.update(voice.id) { clip in
        ClipSourceSwap.shift(&clip, by: 2 - clip.sourceStart)
        clip.sourceStart = 2
        clip.sourceURL = otherVoice
    }
    let voiceReport = TimelineLinkage.follow(from: voiced, to: &revoiced, deletesContent: false)
    check(voiceReport.isEmpty, "配音段换了声音文件：联动什么都不动（got \(voiceReport)）")
    checkEqual(revoiced.subtitleCue(line.id)?.start, 10.2, "它的字幕原地不动")
    checkEqual(revoiced.subtitleCue(line.id)?.end, 11.8, "…结尾也不动")
}

import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// edit_clip 的 file：一段换成另一个文件，位置、长度、设置都不动（2026-10-14 用户拍板）。规则在 ClipFileReplacement（纯值），
// 链接伙伴只跟换完之后的改动在 AIClipEdit。约束见 docs/architecture/ai-control-mcp.md 第四节第 48 条。

private let other = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/other.mp4")
private let photo = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/photo.png")
private let still = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/photo-still.mov")
private let voice = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/voice.m4a")

private func info(_ width: Double, _ height: Double, duration: Double, sound: Bool = true) -> MediaInfo {
    MediaInfo(
        duration: duration, displaySize: CGSize(width: width, height: height), frameRate: 30,
        videoCodec: "h264", audioCodec: sound ? "aac" : nil, hasAudio: sound, audioCanCopyToMP4: sound, fileBytes: 1
    )
}

private func video(duration: Double, width: Double = 1920, height: Double = 1080, sound: Bool = true) -> ClipFileReplacement {
    ClipFileReplacement(
        url: other, kind: .video, duration: duration, info: info(width, height, duration: duration, sound: sound), hasAudio: sound
    )
}

func runClipFileSwapChecks() {
    swapChecks()
    refusalChecks()
    partnerChecks()
}

private func swapChecks() {
    // V1 的 3–7 秒放着 source.mp4 的 10–14 秒：源 11 秒有一个关键帧、源 12 秒有一个标记，裁了边、调过音量。
    var clip = videoClip(3, 4, sourceStart: 10)
    var scale = KeyframeTrack()
    scale.set(1.2, atSourceTime: 11, tolerance: 0.01)
    clip.animation = ClipAnimation(width: scale, height: scale)
    clip.markers = [ClipMarker(sourceTime: 12)]
    clip.crop = ClipCrop(leading: 0.1)
    clip.volume = 0.5
    let before = clip
    do {
        try ClipFileReplacement.apply(video(duration: 20), to: &clip, sourceStart: 2, stillDuration: 60)
    } catch {
        check(false, "a long enough video swaps in: \(error)")
    }
    checkEqual(clip.sourceURL, other, "the clip reads the new file")
    checkEqual(clip.sourceStart, 2, "from source_in")
    checkEqual(clip.sourceDuration, 4, "the length stays")
    checkEqual(clip.timelineStart, 3, "the place stays")
    checkEqual(clip.animation?.width.keys.first?.time, 3, "a keyframe keeps its place in the clip (11 - 10 + 2)")
    checkEqual(clip.markers.first?.sourceTime, 4, "a marker keeps its place in the clip")
    checkEqual(clip.crop, before.crop, "the crop stays")
    checkEqual(clip.volume, 0.5, "the volume stays")
    checkEqual(clip.id, before.id, "it is the same clip (same id)")

    // 换成图片：读转好的静帧视频、记原图、从 0 开始。
    var picture = videoClip(0, 5, sourceStart: 8)
    let image = ClipFileReplacement(url: photo, kind: .image, duration: 0, info: info(1080, 1920, duration: 60), hasAudio: false, stillVideo: still)
    try? ClipFileReplacement.apply(image, to: &picture, sourceStart: 3, stillDuration: 60)
    checkEqual(picture.sourceURL, still, "an image plays from its converted still video")
    checkEqual(picture.stillImageURL, photo, "and remembers the image")
    checkEqual(picture.sourceStart, 0, "an image always starts at 0")
    checkEqual(picture.sourceDuration, 5, "the length stays")
    check(ClipFileReplacement.aspectNote(old: videoClip(0, 5), new: picture) != nil, "16:9 → 9:16 says to fit the picture again")
    check(ClipFileReplacement.aspectNote(old: videoClip(0, 5), new: clip) == nil, "the same shape says nothing")

    // 声音段换成一个视频文件：只取它的声音。
    var sound = audioClip(0, 6)
    try? ClipFileReplacement.apply(video(duration: 30), to: &sound, sourceStart: 1, stillDuration: 60)
    checkEqual(sound.sourceURL, other, "a sound clip can take a video file's sound")
    checkEqual(sound.isAudioOnly, true, "it stays a sound clip")
    checkEqual(sound.assetDuration, 30, "its length is the new file's")
    var song = audioClip(0, 6)
    let audio = ClipFileReplacement(url: voice, kind: .audio, duration: 9, info: nil, hasAudio: true)
    try? ClipFileReplacement.apply(audio, to: &song, sourceStart: 0, stillDuration: 60)
    checkEqual(song.sourceURL, voice, "a sound clip takes an audio file")
}

private func refusalChecks() {
    let clip = videoClip(3, 4, sourceStart: 10)
    func refuses(_ replacement: ClipFileReplacement, on original: EditClip, from start: Double = 0, _ message: String) {
        var copy = original
        checkThrows(message) { try ClipFileReplacement.apply(replacement, to: &copy, sourceStart: start, stillDuration: 60) }
        check(copy == original, "\(message): the clip is left as it was")
    }
    refuses(video(duration: 5), on: clip, from: 2, "a file too short for the clip from source_in is refused")
    refuses(ClipFileReplacement(url: voice, kind: .audio, duration: 9, info: nil, hasAudio: true), on: clip, "a picture clip does not take an audio file")
    refuses(ClipFileReplacement(url: photo, kind: .image, duration: 0, info: nil, hasAudio: false), on: audioClip(0, 4), "a sound clip does not take an image")
    refuses(video(duration: 30, sound: false), on: audioClip(0, 4), "a sound clip does not take a silent video")
    let image = ClipFileReplacement(url: photo, kind: .image, duration: 0, info: nil, hasAudio: false, stillVideo: still)
    refuses(image, on: videoClip(0, 90, asset: 120), "an image cannot show longer than a still lasts")
}

private func partnerChecks() {
    // 画面和分出来的声音链接着；换画面的文件，声音不跟着挪源时间（它还是原来那个文件的声音）。
    var state = TimelineState()
    var picture = videoClip(0, 4, sourceStart: 10)
    var sound = EditClip(
        sourceURL: picture.sourceURL, isAudioOnly: true, sourceStart: 10, sourceDuration: 4, timelineStart: 0, audioAssetDuration: 60
    )
    let group = UUID()
    picture.linkGroup = group
    picture.isMuted = true
    sound.linkGroup = group
    state.mainClips = [picture]
    state.audioTracks = [EditLane(clips: [sound])]
    var change = AIClipChange()
    change.replacement = video(duration: 20)
    change.sourceIn = 5
    let swapped = try? AIClipEdit.apply(change, to: picture.id, linkage: true, stillDuration: 60, in: state)
    checkEqual(swapped?.clip(with: picture.id)?.sourceStart, 5, "the picture reads the new file from 5 s")
    checkEqual(swapped?.clip(with: sound.id)?.sourceStart, 10, "its linked sound does not follow the swap")

    // 换文件的同时挪起点：伙伴照旧跟着挪（换完之后的改动照旧一起）。
    change.start = 2
    let moved = try? AIClipEdit.apply(change, to: picture.id, linkage: true, stillDuration: 60, in: state)
    checkEqual(moved?.clip(with: sound.id)?.timelineStart, 2, "a move made with the swap still carries the linked sound")
    checkEqual(moved?.clip(with: sound.id)?.sourceStart, 10, "…without shifting what it reads")
}

import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 视频的声音单独放到音频轨上（J/L cut，2026-10-14 用户拍板）：add_clips 的 sound=separate 和界面上的分离音频
// 同一份规则（ClipSoundSeparation），sound=only 只要声音，edit_clip 的 alone 让画面和分出来的声音各自裁。
// 规矩见 docs/architecture/ai-control-mcp.md 第四节第 47 条。

func runClipSoundChecks() {
    separateChecks()
    batchChecks()
    aloneChecks()
}

private func separateChecks() {
    var state = TimelineState()
    var picture = videoClip(2, 4, sourceStart: 1)
    picture.volume = 0.5
    state.mainClips = [picture]
    let soundID = ClipSoundSeparation.separate(picture.id, in: &state)
    let sound = soundID.flatMap { state.clip(with: $0) }
    check(sound != nil, "a video with sound gets a separated sound clip")
    checkEqual(state.clip(with: picture.id)?.isMuted, true, "the picture is muted: its sound now plays from the audio track")
    checkEqual(sound?.isAudioOnly, true, "the separated clip is sound only")
    checkEqual(sound?.sourceURL, picture.sourceURL, "it reads the same file")
    checkEqual(sound?.timelineStart, 2, "it starts with the picture")
    checkEqual(sound?.sourceStart, 1, "it uses the same part of the file")
    checkEqual(sound?.sourceDuration, 4, "and the same length")
    checkEqual(sound?.volume, 0.5, "the volume goes with the sound")
    check(sound?.linkGroup != nil && sound?.linkGroup == state.clip(with: picture.id)?.linkGroup, "picture and sound are linked")
    checkEqual(soundID.flatMap { state.location(of: $0)?.track }, .audio(0), "with no audio track yet, the sound opens A1")
    checkEqual(ClipSoundSeparation.sound(of: picture.id, in: state)?.id, soundID, "the sound is found back from its picture")

    // 只要声音（sound=only）：不链接、没有画面。
    let only = picture.detachedAudio(linkGroup: nil)
    check(only.isAudioOnly && only.linkGroup == nil, "sound=only is a sound-only clip linked to nothing")

    // 不能分的：没有声音的视频、静音的段、只有声音的段 —— 一样都不改。
    var silent = videoClip(0, 3)
    silent.info?.hasAudio = false
    var muted = videoClip(5, 3)
    muted.isMuted = true
    var others = TimelineState()
    others.mainClips = [silent, muted]
    others.audioTracks = [EditLane(clips: [audioClip(0, 3)])]
    let before = others
    for id in [silent.id, muted.id, others.audioTracks[0].clips[0].id] {
        check(ClipSoundSeparation.separate(id, in: &others) == nil, "nothing to separate on a silent, muted or sound-only clip")
    }
    check(others == before, "a clip that cannot be separated changes nothing")
}

private func batchChecks() {
    // add_clips 一批两段 sound=separate：画面照常接在 V1 上，声音各落第一条放得下的音频轨、各自和自己的画面链接。
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(0, 3)])]
    let first = videoClip(0, 4)
    let second = videoClip(0, 5)
    AITimelineEdits.place([
        AITimelineEdits.PlannedClip(clip: first, isAudio: false, target: nil, start: nil, separateSound: true),
        AITimelineEdits.PlannedClip(clip: second, isAudio: false, target: nil, start: nil, separateSound: true)
    ], insert: false, linkage: true, in: &state)
    checkEqual(mainStarts(state), [0, 4], "the pictures go on V1 as usual")
    let firstSound = ClipSoundSeparation.sound(of: first.id, in: state)
    let secondSound = ClipSoundSeparation.sound(of: second.id, in: state)
    checkEqual(firstSound?.timelineStart, 0, "the first sound starts with its picture")
    checkEqual(firstSound.flatMap { state.location(of: $0.id)?.track }, .audio(1), "A1 is taken at 0, so the first sound opens A2")
    checkEqual(secondSound?.timelineStart, 4, "the second sound starts with its picture")
    checkEqual(secondSound.flatMap { state.location(of: $0.id)?.track }, .audio(0), "A1 is free after 3 s, so the second sound goes there")
    check(state.mainClips.allSatisfy(\.isMuted), "both pictures are muted")
    check(firstSound?.linkGroup != secondSound?.linkGroup, "each picture is linked to its own sound only")
}

private func aloneChecks() {
    // 画面在 V1 的 4–9 秒（文件的 20–25 秒），声音分到了 A1。
    var state = TimelineState()
    let picture = videoClip(4, 5, sourceStart: 20)
    state.mainClips = [picture]
    guard let soundID = ClipSoundSeparation.separate(picture.id, in: &state) else {
        check(false, "the sound separates")
        return
    }

    // J cut：声音提前 1 秒开始（起点和入点都往前 1 秒），alone 时画面不动。
    var jCut = AIClipChange()
    jCut.start = 3
    jCut.sourceIn = 19
    jCut.alone = true
    let joined = try? AIClipEdit.apply(jCut, to: soundID, linkage: true, stillDuration: 5, in: state)
    checkEqual(joined?.clip(with: soundID)?.timelineStart, 3, "alone: the sound starts a second earlier")
    checkEqual(joined?.clip(with: soundID)?.sourceStart, 19, "alone: …from a second earlier in the file")
    checkEqual(joined?.clip(with: picture.id)?.timelineStart, 4, "alone: the picture stays where it was")
    checkEqual(joined?.clip(with: picture.id)?.sourceStart, 20, "alone: …with its own in point")

    // 不加 alone：链接着的画面照旧跟着一起改（挪和裁默认还是一起）。
    jCut.alone = false
    let together = try? AIClipEdit.apply(jCut, to: soundID, linkage: true, stillDuration: 5, in: state)
    checkEqual(together?.clip(with: picture.id)?.timelineStart, 3, "without alone the linked picture moves along")
    checkEqual(together?.clip(with: picture.id)?.sourceStart, 19, "without alone the linked picture is trimmed along")

    // L cut：画面先切走（出点提前 2 秒），声音照旧放完。
    var lCut = AIClipChange()
    lCut.sourceOut = 23
    lCut.alone = true
    let split = try? AIClipEdit.apply(lCut, to: picture.id, linkage: true, stillDuration: 5, in: state)
    checkEqual(split?.clip(with: picture.id)?.timelineEnd, 7, "alone: the picture ends two seconds earlier")
    checkEqual(split?.clip(with: soundID)?.timelineEnd, 9, "alone: the sound plays on to its end")
}

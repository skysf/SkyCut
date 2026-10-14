import Foundation
import SrtFlowMCPKit

// duplicate_items（AIDuplicate）：走 ⌘C / ⌘V 那两个纯函数 —— 不给落点紧接在后面、落在占着的地方往上抬一轨、
// 链接的声音跟着来、文字找空的行、每样换新身份；不认识的 id 报错。编法见 scripts/check-mcp.sh。

func runDuplicateChecks() {
    var state = TimelineState()
    let first = videoClip(0, 4)
    let second = videoClip(4, 4)
    state.mainClips = [first, second]
    var linked = audioClip(0, 4)
    let group = UUID()
    linked.linkGroup = group
    state.mainClips[0].linkGroup = group
    state.audioTracks = [EditLane(clips: [linked])]
    let title = TextOverlay(text: "南极", timelineStart: 1)
    state.textOverlays = [title]

    // 第二段复制一份、不给落点：紧接在它后面（8 秒），V1 那儿是空的。
    var after = state
    let appended = try? AIDuplicate.apply(
        try AIDuplicate.selection([second.id], in: state, linkage: true), to: &after, at: nil, track: nil
    )
    let copy = appended.flatMap { $0.clips.first }.flatMap { after.clip(with: $0) }
    checkEqual(copy?.timelineStart, 8, "no start: the copy goes right after the original")
    check(copy.map { $0.id != second.id } ?? false, "the copy has a new id")
    checkEqual(after.mainClips.count, 3, "the copy lands on V1 where it is free")

    // 第一段复制到 0 秒：V1 占着，往上抬一轨；链接开着，它的声音跟着来。
    var lifted = state
    let atZero = try? AIDuplicate.apply(
        try AIDuplicate.selection([first.id], in: state, linkage: true), to: &lifted, at: 0, track: nil
    )
    checkEqual(atZero?.clips.count, 2, "the linked audio is copied too")
    checkEqual(lifted.overlayTracks.count, 1, "a copy that would overlap on V1 goes up to a new video track")
    let copiedGroups = Set(lifted.allClips.filter { atZero?.clips.contains($0.id) == true }.compactMap(\.linkGroup))
    check(copiedGroups.count == 1 && !copiedGroups.contains(group), "the copied pair gets a fresh link group of its own")

    var texts = state
    let textCopy = try? AIDuplicate.apply(
        try AIDuplicate.selection([title.id], in: state, linkage: false), to: &texts, at: 1, track: nil
    )
    checkEqual(textCopy?.texts.count, 1, "a text is copied")
    checkEqual(texts.textOverlays.count, 2, "both texts are there")
    checkThrows("an id that does not exist is refused") { _ = try AIDuplicate.selection([UUID()], in: state, linkage: false) }
    checkNewTrackByName(state, linked: linked)
}

/// 2026-10-06 盲测（docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 2 条）：只有 A1 时写 track=A2，
/// 报错说「没有 A2、set_track 只改现有的轨」。和 add_clips 一样：正好多一条（或 new_audio / new_video）就新开一条。
private func checkNewTrackByName(_ state: TimelineState, linked: EditClip) {
    var onA2 = state
    let audio = try? AIDuplicate.apply(
        try AIDuplicate.selection([linked.id], in: state, linkage: false), to: &onA2, at: 0, track: "A2"
    )
    checkEqual(onA2.audioTracks.count, 2, "track=A2 with only A1 opens A2")
    checkEqual(audio.flatMap { $0.clips.first }.flatMap { onA2.location(of: $0)?.track }, .audio(1), "the copy lands on the new A2")
    var newVideo = state
    let video = try? AIDuplicate.apply(
        try AIDuplicate.selection([state.mainClips[1].id], in: state, linkage: false), to: &newVideo, at: 20, track: "new_video"
    )
    checkEqual(video.flatMap { $0.clips.first }.flatMap { newVideo.location(of: $0)?.track }, .overlay(0), "new_video opens V2 for the copy")
    // 指着新开的音频轨、复制的却是画面：画面照常落地，新开的那条空轨收掉，不留空轨。
    var mismatched = state
    _ = try? AIDuplicate.apply(
        try AIDuplicate.selection([state.mainClips[1].id], in: state, linkage: false), to: &mismatched, at: 20, track: "A2"
    )
    checkEqual(mismatched.audioTracks.count, 1, "a new track nothing landed on is not left behind")
    checkThrows("a track two past the last is still unknown") {
        var copy = state
        _ = try AIDuplicate.apply(try AIDuplicate.selection([linked.id], in: state, linkage: false), to: &copy, at: 0, track: "A3")
    }
    do {
        var copy = state
        _ = try AIDuplicate.apply(try AIDuplicate.selection([linked.id], in: state, linkage: false), to: &copy, at: 0, track: "A3")
    } catch {
        check(!"\(error)".contains("set_track"), "the error does not send the AI to set_track: \(error)")
    }
}

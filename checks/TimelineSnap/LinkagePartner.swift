import Foundation
import SrtFlowCore

// 第 1j 组：一段画面自己分出去的声音跟着它自己的画面走（联动规矩 13，2026-11-16）。
//
// J / L 切的声音伸到隔壁镜头底下、跨在两段主轨块上。磁吸开着时调换镜头、裁隔壁那段，自己那段画面被排挪了、隔壁那段没挪（或挪了别的量）：
// 以前按「底下的画面全部挪同一个量才跟」它留在原地，声音和画面错开一整段；删掉第一个镜头时伸到 0 之前的头被夹在 0、整段晚了半秒。
// 现在按它的画面挪（`LinkagePartnerSound`），伸到 0 之前的那截头裁掉（`moveForLinkage`）。换算对不上的声音（被单独挪过的）照老规矩。
// 案例：docs/bugfixes/2026-11-16-separated-sound-left-behind-on-magnet-repack.md。

private let fileZ = URL(fileURLWithPath: "/tmp/srtflow-snap-check/partner-z.mp4")
private let fileA = URL(fileURLWithPath: "/tmp/srtflow-snap-check/partner-a.mp4")
private let fileB = URL(fileURLWithPath: "/tmp/srtflow-snap-check/partner-b.mp4")
private let fileC = URL(fileURLWithPath: "/tmp/srtflow-snap-check/partner-c.mp4")
private let fileP = URL(fileURLWithPath: "/tmp/srtflow-snap-check/partner-p.mp4")

private func shot(_ url: URL, _ start: Double, _ duration: Double, source: Double) -> EditClip {
    let info = MediaInfo(
        duration: 60, displaySize: CGSize(width: 1920, height: 1080), frameRate: 24, videoCodec: "avc1", audioCodec: "aac",
        hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1_000, keyframeInterval: nil
    )
    return EditClip(sourceURL: url, sourceStart: source, sourceDuration: duration, timelineStart: start, info: info)
}

/// 把画面的声音分到一条新的音频轨上、和画面链接（同分离音频），头往前伸 `lead` 秒（J 切）、尾往后伸 `lag` 秒（L 切），换算不变。
private func separate(_ state: inout TimelineState, _ id: UUID, lead: Double = 0, lag: Double = 0) -> UUID {
    guard let picture = state.clip(with: id) else { return UUID() }
    let group = UUID()
    var sound = picture.detachedAudio(linkGroup: group)
    sound.timelineStart -= lead
    sound.sourceStart -= lead
    sound.sourceDuration += lead + lag
    sound.fadeInDuration = lead
    state.update(id) { $0.isMuted = true; $0.linkGroup = group }
    state.audioTracks.append(EditLane(clips: [sound]))
    return sound.id
}

/// 照 `perform` 的收尾：磁吸排 V1，再联动。
private func settle(_ next: inout TimelineState, after before: TimelineState, deletes: Bool = false) {
    MainMagnet.settle(&next, after: before)
    TimelineLinkage.follow(from: before, to: &next, deletesContent: deletes)
}

/// 声音和画面对得上：同一个源时刻在时间线上同一刻。
private func inSync(_ sound: UUID, _ picture: UUID, _ state: TimelineState, at source: Double) -> Bool {
    guard let s = state.clip(with: sound), let p = state.clip(with: picture) else { return false }
    return abs(s.timelineTime(atSource: source) - p.timelineTime(atSource: source)) < 0.001
}

func checkLinkagePartner() {
    // V1（磁吸开）：Z [0,2)、A [2,6)、B [6,10)、C [10,14)；B 的声音先进半秒（J 切，从 5.5 起，伸在 A 底下）。
    var base = TimelineState()
    base.mainMagnet = true
    let z = shot(fileZ, 0, 2, source: 0)
    let a = shot(fileA, 2, 4, source: 10)
    let b = shot(fileB, 6, 4, source: 20)
    let c = shot(fileC, 10, 4, source: 30)
    base.mainClips = [z, a, b, c]
    let sound = separate(&base, b.id, lead: 0.5)

    // 把 A 挪到最后（磁吸重排）：B 往前挪 4 秒，它的声音跟着挪 4 秒（以前跨在 A、B 上、两边挪的不一样 → 留在原地）。
    var reorder = base
    reorder.mainClips = [z, base.mainClips[2], base.mainClips[3], a]
    settle(&reorder, after: base)
    checkClose(reorder.clip(with: b.id)?.timelineStart ?? -1, 2, "1j 重排：B 被磁吸排到 2")
    checkClose(reorder.clip(with: sound)?.timelineStart ?? -1, 1.5, "1j 重排：B 的 J 切声音跟着 B 挪到 1.5")
    check(inSync(sound, b.id, reorder, at: 21), "1j 重排：B 的声音和画面对得上")

    // 裁 A 的尾巴 0.25 秒（磁吸把后面的排上来）：B 往前 0.25，它的声音也往前 0.25（以前 A 底下那一截没挪 → 留在原地）。
    var trim = base
    trim.mainClips[1].sourceDuration = 3.75
    settle(&trim, after: base)
    checkClose(trim.clip(with: sound)?.timelineStart ?? -1, 5.25, "1j 裁隔壁：B 的声音跟着 B 往前 0.25")
    check(inSync(sound, b.id, trim, at: 21), "1j 裁隔壁：B 的声音和画面对得上")

    // 换算对不上的声音（被单独往后挪过 0.3 秒）不算画面自己的，照老规矩：跨在挪得不一样的两段上就不动。
    var slipped = base
    slipped.update(sound) { $0.timelineStart += 0.3 }
    var slippedReorder = slipped
    slippedReorder.mainClips = [z, slipped.mainClips[2], slipped.mainClips[3], a]
    settle(&slippedReorder, after: slipped)
    checkClose(slippedReorder.clip(with: sound)?.timelineStart ?? -1, 5.8, "1j 挪过的声音不认作画面自己的，照老规矩留在原地")

    // 删掉第一个镜头（真删、磁吸开）：B 排到 0，J 切伸到 0 之前的那半秒头裁掉、入点跟着挪，不整段晚半秒。
    var first = TimelineState()
    first.mainMagnet = true
    let a2 = shot(fileA, 0, 4, source: 10)
    let b2 = shot(fileB, 4, 4, source: 20)
    first.mainClips = [a2, b2]
    let lead = separate(&first, b2.id, lead: 0.5)
    var deleted = first
    deleted.mainClips.removeAll { $0.id == a2.id }
    settle(&deleted, after: first, deletes: true)
    checkClose(deleted.clip(with: lead)?.timelineStart ?? -1, 0, "1j 删第一个镜头：B 的声音从 0 起")
    checkClose(deleted.clip(with: lead)?.sourceStart ?? -1, 20, "1j 删第一个镜头：伸到 0 之前的头裁掉（入点 19.5 → 20）")
    checkClose(deleted.clip(with: lead)?.fadeInDuration ?? -1, 0, "1j 删第一个镜头：被裁掉的那截渐入跟着没了")
    check(inSync(lead, b2.id, deleted, at: 21), "1j 删第一个镜头：B 的声音和画面对得上")

    // 上层轨的画面 P（压在 A 上）自己分出去的声音拖到 B 底下（L 切）。把 B 挪到最前：A 往后 4 秒，P 跟着 A，P 的声音跟着 P。
    var upper = TimelineState()
    upper.mainMagnet = true
    let z3 = shot(fileZ, 0, 2, source: 0)
    let a3 = shot(fileA, 2, 4, source: 10)
    let b3 = shot(fileB, 6, 4, source: 20)
    let p = shot(fileP, 3, 2, source: 40)
    upper.mainClips = [z3, a3, b3]
    upper.overlayTracks = [EditLane(clips: [p])]
    let tail = separate(&upper, p.id, lag: 1.5)
    var front = upper
    front.mainClips = [b3, z3, a3]
    settle(&front, after: upper)
    checkClose(front.clip(with: p.id)?.timelineStart ?? -1, 7, "1j 上层轨：P 跟着 A 往后 4 秒")
    check(inSync(tail, p.id, front, at: 41), "1j 上层轨：P 的 L 切声音跟着 P（以前跨在 A、B 上 → 留在原地）")
}

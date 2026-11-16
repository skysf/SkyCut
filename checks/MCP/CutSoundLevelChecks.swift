import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 声音怎么过一刀（续，CutSoundChecks 的后半）：调增益（对齐电平、给定 dB、到顶被夹住、音量曲线整条平移、推子算进去）、
// 垫一层底（伸到两边各 N 帧、余料不够、自动挑最长的那段、不许拿两边自己的声音、比底响 6 dB 以上的压下来、底是静的不压）、
// 落在拍子上（取整到帧、窗外没拍子、挪不过去的拍子跳过、正好在切点上不分离）、几刀一起（棋盘似的两条轨、缺声音的跳过）、
// 结果的样子、联动开着时后来的改动（删掉第一个镜头：J 切的声音裁掉伸到 0 之前的头、和画面对得上）。
// 素材电平和拍子是 App 量好传进来的（CutSoundMeasure），这里直接给数。规矩见 docs/architecture/cut-sound.md。

func runCutSoundLevelChecks() {
    gainChecks()
    bedChecks()
    onBeatChecks()
    severalCutsChecks()
    reportChecks()
    laterEditChecks()
}

private func gainChecks() {
    let (state, a, b) = cutPair()
    let quiet = CutSoundPlanner.Material(outgoing: -20, incoming: -30)
    if let done = try? joinSound(state, after: a.id, .gain, material: quiet) {
        checkEqual(done.state.clip(with: b.id)?.volume, AudioGain.maximumLinear, "gain: +10 dB asked, the clip volume tops out at +6 dB")
        checkNear(done.outcome.gains.first?.requested, 10, "gain: the result keeps what was asked")
        checkNear(done.outcome.gains.first?.applied, AudioGain.maximumDB, "gain: …and what was applied")
        checkEqual(done.state.audioTracks.isEmpty, true, "gain: nothing is separated (only the level changes)")
        checkNear(done.outcome.levels?.outgoing, -20, "gain: the heard level before the cut is reported")
    } else { check(false, "gain with measured levels works") }
    if let done = try? joinSound(state, after: a.id, .gain, material: .init(outgoing: -20, incoming: -14)) {
        checkNear(done.state.clip(with: b.id).map { AudioGain.decibels(fromLinear: $0.volume) }, -6, "gain: a louder next shot comes down 6 dB")
        checkEqual(done.state.clip(with: a.id)?.volume, 1, "gain: the previous shot is not touched")
    } else { check(false, "gain down works") }
    if let done = try? joinSound(state, after: a.id, .gain, gain: -3) {
        checkNear(done.state.clip(with: b.id).map { AudioGain.decibels(fromLinear: $0.volume) }, -3, "gain_db -3: set without measuring")
    } else { check(false, "gain with gain_db works") }
    checkThrows("gain with a silent side has no level to match") {
        _ = try joinSound(state, after: a.id, .gain, material: .init(outgoing: -20, incoming: nil))
    }

    // 音量曲线整条平移；分出去的声音在 A1，A1 的推子 -6 dB 算进听到的电平。
    var curved = state
    curved.mainClips[1].volumeCurve = KeyframeTrack(keys: [Keyframe(time: 20, value: -6), Keyframe(time: 22, value: 0)])
    if let done = try? joinSound(curved, after: a.id, .gain, gain: -3) {
        checkEqual(done.state.clip(with: b.id)?.volumeCurve.keys.map(\.value), [-9, -3], "gain on a curve: the whole curve moves")
    } else { check(false, "gain on a curved clip works") }
    var fader = state
    if let sound = ClipSoundSeparation.separate(b.id, in: &fader) {
        fader.audioTracks[0].volume = 0.5
        if let done = try? joinSound(fader, after: a.id, .gain, material: .init(outgoing: -20, incoming: -20)) {
            checkEqual(done.outcome.incoming, sound, "gain: a separated sound is the one that changes")
            checkNear(done.outcome.gains.first?.requested, -AudioGain.decibels(fromLinear: 0.5), "gain: the track fader counts in the level")
        } else { check(false, "gain on a separated sound works") }
    }
}

private func bedChecks() {
    let (base, a, b) = cutPair()
    var state = base
    let music = audioClip(0, 3)
    state.audioTracks = [EditLane(clips: [music])]
    let levels = CutSoundPlanner.Material(outgoing: -10, incoming: -30, layer: -25)
    if let done = try? joinSound(state, after: a.id, .bed, material: levels) {
        checkEqual(done.outcome.bed?.clip, music.id, "bed: the music across the cut is the bed")
        checkNear(done.state.clip(with: music.id)?.timelineEnd, 6, "bed: it is made to reach 2 s (48 frames) past the cut")
        checkEqual(done.outcome.bed?.extendedAfter, 72, "bed: 72 frames were added after it")
        checkEqual(done.outcome.bed?.extendedBefore, 0, "bed: it already reached 2 s before the cut")
        checkNear(done.state.clip(with: a.id).map { AudioGain.decibels(fromLinear: $0.volume) }, -9,
                  "bed: the side 15 dB over the bed comes down to bed + 6 dB")
        checkEqual(done.state.clip(with: b.id)?.volume, 1, "bed: the side under bed + 6 dB is left alone (never raised)")
        check(done.state.audioTracks.count == 1 && !done.state.mainClips.contains(where: \.isMuted), "bed: no sound is separated")
    } else { check(false, "bed works") }
    if let done = try? joinSound(state, after: a.id, .bed, material: .init(outgoing: -10, incoming: -30, layer: nil)) {
        checkEqual(done.state.clip(with: a.id)?.volume, 1, "bed silent at the cut: the sides are left as they are")
        check(!done.outcome.notes.isEmpty, "bed silent at the cut: the result says why")
    } else { check(false, "bed with a silent bed works") }

    var short = state
    short.audioTracks = [EditLane(clips: [audioClip(0, 3, asset: 5)])]
    checkFramesRefused("bed whose file ends 1 s after the cut", maximum: 24, suggested: 24) {
        _ = try joinSound(short, after: a.id, .bed, material: levels)
    }
    // 自动挑：和切点两边重叠最多的那段（整段音乐，不是切点上的一下音效）；两边自己的声音不能当底。
    var pick = cutPair().state
    let hit = audioClip(3.9, 0.2)
    let score = audioClip(0, 10)
    pick.audioTracks = [EditLane(clips: [score]), EditLane(clips: [hit])]
    let cut = try? CutSoundCut.after(pick.mainClips[0].id, in: pick)
    checkEqual(cut.flatMap { try? CutSoundCut.layer(for: CutSoundRequest(mode: .bed), at: $0, in: pick) }?.id, score.id,
               "bed: picks the sound that covers most of the cut")
    var own = cutPair().state
    if let sound = ClipSoundSeparation.separate(own.mainClips[1].id, in: &own) {
        checkThrows("bed: a side's own sound cannot be the bed") {
            _ = try joinSound(own, after: own.mainClips[0].id, .bed, layer: sound, material: levels)
        }
    }
}

private func onBeatChecks() {
    let (base, a, _) = cutPair()
    var state = base
    state.audioTracks = [EditLane(clips: [audioClip(0, 10)])]
    if let done = try? joinSound(state, after: a.id, .onBeat, beats: [3.9, 4.6]) {
        let edge = 4 - 2.0 / 24
        checkEqual(done.outcome.beat?.offsetFrames, -2, "on_beat: the beat 2.4 frames early lands 2 frames early")
        checkNear(done.outcome.outgoing.flatMap { done.state.clip(with: $0) }?.timelineEnd, edge, "on_beat: the previous sound stops there")
        checkNear(done.outcome.incoming.flatMap { done.state.clip(with: $0) }?.timelineStart, edge, "on_beat: the next sound starts there")
        checkEqual(done.outcome.incoming.flatMap { done.state.clip(with: $0) }?.fadeInDuration, 0, "on_beat: a hard switch, no fade")
        checkEqual(mainStarts(done.state), [0, 4], "on_beat: the picture cut stays")
    } else { check(false, "on_beat works") }
    if let done = try? joinSound(state, after: a.id, .onBeat, beats: [4.0]) {
        checkEqual(done.outcome.beat?.offsetFrames, 0, "on_beat: a beat right on the cut moves nothing")
        check(done.state.audioTracks.count == 1 && !done.state.mainClips.contains(where: \.isMuted),
              "on_beat on the cut: nothing is separated")
    } else { check(false, "on_beat on the cut works") }
    do {
        _ = try joinSound(state, after: a.id, .onBeat, beats: [4.6])
        check(false, "on_beat: a beat 14 frames away is outside the default 8-frame search")
    } catch let error as AIToolError {
        checkEqual(error.details["suggested"]?.doubleValue, 14, "on_beat: says how far the nearest beat is")
    } catch { check(false, "unexpected \(error)") }
    // 最近的那一拍（早 1 帧）挪不过去：B 的文件在入点之前只有半帧。跳过它，落在晚 5 帧的那一拍上。
    var tight = state
    tight.mainClips[1].sourceStart = 0.02
    if let done = try? joinSound(tight, after: a.id, .onBeat, beats: [3.95, 4.2]) {
        checkEqual(done.outcome.beat?.offsetFrames, 5, "on_beat: a beat it cannot reach is skipped for the next nearest")
        checkNear(done.outcome.incoming.flatMap { done.state.clip(with: $0) }?.sourceStart, 0.02 + 5.0 / 24,
                  "on_beat: the next sound's head is trimmed to the beat")
    } else { check(false, "on_beat past an unreachable beat works") }
}

private func severalCutsChecks() {
    var state = cutPair().state
    state.mainClips.append(cutShot(cutFileC, 8, 4, source: 30))
    let cuts = CutSoundCut.everyMainCut(in: state)
    checkEqual(cuts.count, 2, "all=true: two cuts on V1")
    var next = state
    let inputs = Array(repeating: CutSoundPlanner.Inputs(), count: cuts.count)
    guard let done = try? CutSoundPlanner.run(CutSoundRequest(mode: .crossfade, frames: 6), cuts: cuts, inputs: inputs,
                                              skipsSilent: true, in: &next) else { return check(false, "crossfade on every cut works") }
    let middle = done.outcomes[0].incoming.flatMap { next.clip(with: $0) }
    checkEqual(done.outcomes[1].outgoing, middle?.id, "all=true: the middle shot's sound is separated once and used at both cuts")
    checkNear(middle?.timelineStart, 3.75, "all=true: the middle sound starts 6 frames before its first cut")
    checkNear(middle?.timelineEnd, 8.25, "all=true: …and ends 6 frames after its second")
    let tracks = done.outcomes.flatMap { [$0.outgoing, $0.incoming] }.map { cutTrack($0, next) }
    checkEqual(tracks, [.audio(0), .audio(1), .audio(1), .audio(0)], "all=true: overlapping sounds alternate between two tracks")

    var silent = state
    silent.mainClips[2].isMuted = true
    var after = silent
    let skipped = try? CutSoundPlanner.run(CutSoundRequest(mode: .crossfade, frames: 6), cuts: CutSoundCut.everyMainCut(in: silent),
                                           inputs: inputs, skipsSilent: true, in: &after)
    checkEqual(skipped?.skipped, [silent.mainClips[1].id], "all=true: a cut without the sound it needs is skipped and listed")
    checkEqual(skipped?.outcomes.count, 1, "all=true: the other cut is still joined")
    // B 的文件在入点之前只有 2 帧：第一刀叠不了 6 帧，整个调用都不做（第二刀也不做），报错点名是第几刀。
    var short = state
    short.mainClips[1].sourceStart = 0.1
    let untouched = short
    let shortCuts = CutSoundCut.everyMainCut(in: short)
    do {
        _ = try CutSoundPlanner.run(CutSoundRequest(mode: .crossfade, frames: 6), cuts: shortCuts, inputs: inputs, skipsSilent: true, in: &short)
        check(false, "several cuts: one cut that cannot be done stops the whole call")
    } catch let error as AIToolError {
        check(error.message.hasPrefix("Cut after"), "several cuts: the refusal names which cut")
    } catch { check(false, "unexpected \(error)") }
    checkEqual(short, untouched, "several cuts: a refused call changes nothing")
}

private func reportChecks() {
    let (state, a, b) = cutPair()
    guard let done = try? joinSound(state, after: a.id, .lead, frames: 12) else { return check(false, "lead for the report works") }
    let ids = AIShortIDs(state: done.state)
    let json = CutSoundReport.json([done.outcome], in: done.state, ids: ids)
    let cut = json["cuts"]?.arrayValue?.first
    checkEqual(json["sound"]?.stringValue, "lead", "report: the join")
    checkEqual(json["picture"]?.stringValue, "unchanged", "report: the picture is untouched")
    checkEqual(cut?["in"]?["starts"]?.doubleValue, 3.5, "report: where the next sound starts")
    checkEqual(cut?["in"]?["offset_frames"]?.doubleValue, -12, "report: 12 frames before the picture cut")
    checkEqual(cut?["in"]?["fade_frames"]?.doubleValue, 12, "report: fading in over 12 frames")
    checkEqual(cut?["in"]?["separated_from"]?.stringValue, ids.short(b.id), "report: separated from the next picture")
    checkEqual(cut?["in"]?["track"]?.stringValue, "A1", "report: on A1")
    checkEqual(cut?["out"]?["ends"]?.doubleValue, 4, "report: the previous sound (still the picture's) ends on the cut")
    checkEqual(cut?["room_frames"]?["in"]?.doubleValue, 480, "report: frames of sound left in the next file before the cut")
    checkEqual(cut?["room_frames"]?["out"]?.doubleValue, 1104, "report: …and in the previous file after it")
    guard let loud = try? joinSound(state, after: a.id, .gain, material: .init(outgoing: -20, incoming: -30)) else { return }
    let clamped = CutSoundReport.json([loud.outcome], in: loud.state, ids: AIShortIDs(state: loud.state))["cuts"]?.arrayValue?.first?["in"]
    checkEqual(clamped?["requested_gain_db"]?.doubleValue, 10, "report: a clamped gain shows what was asked")
    checkEqual(clamped?["gain_db"]?.doubleValue, 6, "report: …and what was applied")
}

private func laterEditChecks() {
    // 联动开着、磁吸开着：先进 12 帧之后删掉第一个镜头 A。B 排到 0，它的声音跟着走；伸到 0 之前的那半秒裁掉（入点跟着挪），不整段往后错。
    let (state, a, b) = cutPair()
    guard let done = try? joinSound(state, after: a.id, .lead, frames: 12), let sound = done.outcome.incoming else {
        return check(false, "lead before the delete works")
    }
    var next = done.state
    next.mainMagnet = true
    next.mainClips.removeAll { $0.id == a.id }
    next.packMain()
    TimelineLinkage.follow(from: done.state, to: &next, deletesContent: true)
    let moved = next.clip(with: sound)
    let picture = next.clip(with: b.id)
    checkNear(moved?.timelineStart, 0, "later edit: the J-cut sound of the first shot starts at 0")
    checkNear(moved?.sourceStart, 20, "later edit: …its head before 0 is trimmed, not shifted")
    checkNear(moved?.timelineTime(atSource: 21), picture?.timelineTime(atSource: 21) ?? -1, "later edit: sound and picture stay in sync")
    checkEqual(moved?.fadeInDuration, 0, "later edit: the fade-in that was before 0 is gone with it")
}

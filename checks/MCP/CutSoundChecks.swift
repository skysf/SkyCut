import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 声音怎么过一刀（set_transition 的 sound，2026-11-16 MCP-32）：叠着换 / 先进 / 拖后 / 一刀切 —— 对着结果的时间、渐变、轨道逐项断言；
// 场景含余料不够（整个不做、报最多几帧）、两边是同一素材、切点在转场上（另一头的转场照样响）、磁吸开着（V1 不动）、上层轨的刀、
// 词表对账、默认帧数、参数核对。量电平的两种、落在拍子上、几刀一起、结果的样子、联动开着在 CutSoundLevelChecks。
// 规矩见 docs/architecture/cut-sound.md。

let cutFileA = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/cut-a.mp4")
let cutFileB = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/cut-b.mp4")
let cutFileC = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/cut-c.mp4")

/// 一段有声音的镜头：文件 `url` 的 `source` 秒起、`duration` 秒长，放在时间线 `start`；文件本身 `asset` 秒。
func cutShot(_ url: URL, _ start: Double, _ duration: Double, source: Double, asset: Double = 60) -> EditClip {
    let info = MediaInfo(
        duration: asset, displaySize: CGSize(width: 1920, height: 1080), frameRate: 24, videoCodec: "h264", audioCodec: "aac",
        hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    )
    return EditClip(sourceURL: url, sourceStart: source, sourceDuration: duration, timelineStart: start, info: info)
}

/// V1：A [0,4) = 文件 A 的 10–14 秒，B [4,8) = 文件 B 的 20–24 秒。24 帧 / 秒（默认）。
func cutPair() -> (state: TimelineState, a: EditClip, b: EditClip) {
    var state = TimelineState()
    let a = cutShot(cutFileA, 0, 4, source: 10)
    let b = cutShot(cutFileB, 4, 4, source: 20)
    state.mainClips = [a, b]
    return (state, a, b)
}

/// 照 set_transition sound 那样做一刀（App 量好的电平、拍子直接传进来）。
func joinSound(
    _ state: TimelineState, after id: UUID, _ mode: CutSoundMode, frames: Int? = nil, gain: Double? = nil, layer: UUID? = nil,
    material: CutSoundPlanner.Material = .init(), beats: [Double] = []
) throws -> (state: TimelineState, outcome: CutSoundOutcome) {
    let request = CutSoundRequest(mode: mode, frames: frames, gainDB: gain, layer: layer)
    let cut = try CutSoundCut.after(id, in: state)
    let input = CutSoundPlanner.Inputs(layer: try CutSoundCut.layer(for: request, at: cut, in: state), material: material, beats: beats)
    var next = state
    let done = try CutSoundPlanner.run(request, cuts: [cut], inputs: [input], skipsSilent: false, in: &next)
    return (next, done.outcomes[0])
}

func checkNear(_ actual: Double?, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) < 1e-6 else {
        failures += 1
        print("FAIL [CutSound:\(line)] \(message): got \(actual.map { String($0) } ?? "nil"), expected \(expected)")
        return
    }
}

/// 这段在哪条轨上。
func cutTrack(_ id: UUID?, _ state: TimelineState) -> TrackSlot? { id.flatMap { state.location(of: $0)?.track } }

/// 做不到的那一刀：报 invalid_parameter（frames）、给最多几帧。
func checkFramesRefused(_ message: String, maximum: Int, suggested: Int?, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        checks += 1
        failures += 1
        print("FAIL [CutSound:\(line)] \(message): expected a refusal, got none")
    } catch let error as AIToolError {
        checkEqual(error.details["parameter"]?.stringValue, "frames", "\(message): names frames", line: line)
        checkEqual(error.details["allowed"]?["maximum"]?.doubleValue, Double(maximum), "\(message): says the most it can do", line: line)
        checkEqual(error.details["suggested"]?.doubleValue, suggested.map(Double.init), "\(message): suggests the maximum", line: line)
        check(error.message.contains("Nothing was changed"), "\(message): says nothing changed", line: line)
    } catch {
        checks += 1
        failures += 1
        print("FAIL [CutSound:\(line)] \(message): unexpected \(error)")
    }
}

func runCutSoundChecks() {
    vocabularyAndDefaults()
    requestChecks()
    crossfadeChecks()
    leadLagChecks()
    hardCutChecks()
    transitionAndMagnetChecks()
    sameFileAndUpperTrackChecks()
    runCutSoundLevelChecks()
}

private func vocabularyAndDefaults() {
    checkEqual(MCPVocabulary.cutSounds, CutSoundMode.allCases.map(\.rawValue), "set_transition sound values match CutSoundMode")
    let defaults: [(ProjectFrameRate, [CutSoundMode: Int])] = [
        (.fps24, [.crossfade: 6, .lead: 16, .lag: 21, .bed: 48, .onBeat: 8]),
        (.fps30, [.crossfade: 8, .lead: 20, .lag: 26, .bed: 60, .onBeat: 10]),
        (.fps60, [.crossfade: 15, .lead: 40, .lag: 53, .bed: 120, .onBeat: 20])
    ]
    for (rate, table) in defaults {
        for (mode, frames) in table {
            checkEqual(CutSoundRequest(mode: mode).resolvedFrames(rate), frames, "\(mode.rawValue) at \(rate.fps) fps defaults to \(frames) frames")
        }
    }
    checkEqual(CutSoundRequest(mode: .lead, frames: 3).resolvedFrames(.fps24), 3, "frames given are used as they are")
    check(!CutSoundMode.gain.usesFrames && !CutSoundMode.cut.usesFrames, "gain and cut take no frames")
}

private func requestChecks() {
    let (state, _, _) = cutPair()
    let read = { (object: [String: JSONValue]) in try CutSoundRequest.read(args(object), state) }
    checkEqual(try? read(["sound": "lead", "frames": 12, "gain_db": -6]), CutSoundRequest(mode: .lead, frames: 12, gainDB: -6),
               "sound, frames and gain_db are read")
    checkThrows("sound with type is two different things") { _ = try read(["sound": "lead", "type": "crossFade"]) }
    checkThrows("sound with duration (picture seconds) is refused") { _ = try read(["sound": "lag", "duration": 0.5]) }
    checkThrows("frames do not apply to gain") { _ = try read(["sound": "gain", "frames": 4]) }
    checkThrows("frames do not apply to cut") { _ = try read(["sound": "cut", "frames": 4]) }
    checkThrows("a crossfade of 0 frames is refused (that is a cut)") { _ = try read(["sound": "crossfade", "frames": 0]) }
    checkThrows("more than 600 frames is refused") { _ = try read(["sound": "lead", "frames": 601]) }
    checkThrows("gain_db does not apply to bed") { _ = try read(["sound": "bed", "gain_db": -3]) }
    checkThrows("layer_id is only for bed and on_beat") { _ = try read(["sound": "lead", "layer_id": "x"]) }
    checkThrows("an unknown sound value is refused") { _ = try read(["sound": "dissolve"]) }
    checkEqual((try? read(["sound": "on_beat", "frames": 0]))?.frames, 0, "on_beat may search 0 frames (only a beat right on the cut)")
}

private func crossfadeChecks() {
    let (state, a, b) = cutPair()
    guard let done = try? joinSound(state, after: a.id, .crossfade, frames: 6) else { return check(false, "crossfade 6 frames works") }
    let s = done.state
    let out = done.outcome.outgoing.flatMap { s.clip(with: $0) }
    let into = done.outcome.incoming.flatMap { s.clip(with: $0) }
    check(out?.isAudioOnly == true && into?.isAudioOnly == true, "crossfade: both sounds are separated onto audio tracks")
    checkEqual(mainStarts(s), [0, 4], "crossfade: the pictures do not move")
    check(s.mainClips.allSatisfy(\.isMuted), "crossfade: both pictures are muted (their sound plays from the audio tracks)")
    checkNear(out?.timelineStart, 0, "crossfade: the outgoing sound still starts with its picture")
    checkNear(out?.timelineEnd, 4.25, "crossfade: the outgoing sound runs 6 frames past the cut")
    checkNear(out?.fadeOutDuration, 0.5, "crossfade: …fading out over the whole 12-frame overlap")
    checkNear(out.map { $0.sourceStart + $0.sourceDuration }, 14.25, "crossfade: …using 6 frames of its file after the out point")
    checkNear(into?.timelineStart, 3.75, "crossfade: the incoming sound starts 6 frames before the cut")
    checkNear(into?.sourceStart, 19.75, "crossfade: …from 6 frames earlier in its file (same moment ↔ same picture)")
    checkNear(into?.fadeInDuration, 0.5, "crossfade: …fading in over the 12-frame overlap")
    checkNear(into?.timelineEnd, 8, "crossfade: the incoming sound still ends with its picture")
    checkEqual(cutTrack(out?.id, s), .audio(0), "crossfade: the outgoing sound keeps A1")
    checkEqual(cutTrack(into?.id, s), .audio(1), "crossfade: the overlapping incoming sound goes to A2")
    checkEqual(out?.linkGroup, s.clip(with: a.id)?.linkGroup, "crossfade: each sound stays linked to its picture")
    checkEqual(Set(done.outcome.separated.values), [a.id, b.id], "crossfade: the result says both were separated")

    // 余料不够：B 只从文件的 0.1 秒用起（2.4 帧），6 帧叠不了；整个不做，报最多 2 帧。
    var short = state
    short.mainClips[1].sourceStart = 0.1
    checkFramesRefused("crossfade with 2 frames of footage before the in point", maximum: 2, suggested: 2) {
        _ = try joinSound(short, after: a.id, .crossfade, frames: 6)
    }
    // B 不出声（静音）：叠着换要两边都有声音。
    var silent = state
    silent.mainClips[1].isMuted = true
    do {
        _ = try joinSound(silent, after: a.id, .crossfade, frames: 6)
        check(false, "crossfade needs sound on both sides")
    } catch let error as AIToolError {
        checkEqual(error.details["status"]?.stringValue, CutSoundPlanner.noSoundStatus, "crossfade without sound on one side says no_sound")
    } catch { check(false, "unexpected \(error)") }
}

private func leadLagChecks() {
    let (state, a, b) = cutPair()
    if let done = try? joinSound(state, after: a.id, .lead, frames: 12, gain: -6) {
        let s = done.state
        let into = done.outcome.incoming.flatMap { s.clip(with: $0) }
        checkNear(into?.timelineStart, 3.5, "lead 12: the next sound starts 12 frames early")
        checkNear(into?.sourceStart, 19.5, "lead 12: …from 12 frames earlier in its file")
        checkNear(into?.fadeInDuration, 0.5, "lead 12: …fading in over those 12 frames")
        checkNear(into.map { AudioGain.decibels(fromLinear: $0.volume) }, -6, "lead 12 gain -6: the next sound is 6 dB down")
        checkEqual(s.clip(with: a.id)?.isMuted, false, "lead: the previous shot keeps its own sound (not separated)")
        checkEqual(done.outcome.outgoing, a.id, "lead: the previous sound is still the picture's")
        checkEqual(s.clip(with: b.id)?.isMuted, true, "lead: the next picture is muted, its sound moved to A1")
        checkEqual(cutTrack(into?.id, s), .audio(0), "lead: the separated sound opens A1")
        checkNear(done.outcome.gains.first?.applied, -6, "lead: the result records the gain as applied")
    } else { check(false, "lead 12 works") }

    var short = state
    short.mainClips[1].sourceStart = 0.2
    checkFramesRefused("lead with 4.8 frames of footage before the in point", maximum: 4, suggested: 4) {
        _ = try joinSound(short, after: a.id, .lead, frames: 12)
    }
    var brief = state
    brief.mainClips[0].sourceDuration = 0.25
    brief.mainClips[1].timelineStart = 0.25
    checkFramesRefused("lead longer than the previous shot", maximum: 6, suggested: 6) {
        _ = try joinSound(brief, after: a.id, .lead, frames: 12)
    }

    if let done = try? joinSound(state, after: a.id, .lag, frames: 21) {
        let out = done.outcome.outgoing.flatMap { done.state.clip(with: $0) }
        checkNear(out?.timelineEnd, 4.875, "lag 21: the previous sound runs 21 frames past the cut")
        checkNear(out?.fadeOutDuration, 0.875, "lag 21: …fading out over them")
        checkEqual(done.state.clip(with: b.id)?.isMuted, false, "lag: the next shot keeps its own sound")
    } else { check(false, "lag 21 works") }
    // A 用到了文件的最后一帧：后面没有素材，拖不过去；最多 0 帧，没有可建议的帧数。
    var end = state
    end.mainClips[0] = cutShot(cutFileA, 0, 4, source: 10, asset: 14)
    checkFramesRefused("lag with no footage after the out point", maximum: 0, suggested: nil) {
        _ = try joinSound(end, after: end.mainClips[0].id, .lag, frames: 6)
    }
}

private func hardCutChecks() {
    let (base, a, b) = cutPair()
    var state = base
    state.mainClips[0].fadeOutDuration = 0.5
    state.mainClips[1].fadeInDuration = 0.3
    if let done = try? joinSound(state, after: a.id, .cut) {
        checkEqual(done.state.clip(with: a.id)?.fadeOutDuration, 0, "cut: the previous shot's fade-out at the cut is cleared")
        checkEqual(done.state.clip(with: b.id)?.fadeInDuration, 0, "cut: the next shot's fade-in at the cut is cleared")
        check(done.state.audioTracks.isEmpty && !done.state.mainClips.contains(where: \.isMuted),
              "cut on a plain cut: nothing is separated")
    } else { check(false, "cut works") }
    // 叠过之后回到一刀切：两段分出去的声音都断回切点上、没有渐变。
    guard let mixed = try? joinSound(base, after: a.id, .crossfade, frames: 6),
          let back = try? joinSound(mixed.state, after: a.id, .cut) else { return check(false, "crossfade then cut works") }
    let out = back.outcome.outgoing.flatMap { back.state.clip(with: $0) }
    let into = back.outcome.incoming.flatMap { back.state.clip(with: $0) }
    checkNear(out?.timelineEnd, 4, "cut after a crossfade: the previous sound ends on the cut again")
    checkNear(into?.timelineStart, 4, "cut after a crossfade: the next sound starts on the cut again")
    checkNear(into?.sourceStart, 20, "cut after a crossfade: …at its picture's in point")
    checkEqual(out?.fadeOutDuration, 0, "cut after a crossfade: no fade-out")
    checkEqual(into?.fadeInDuration, 0, "cut after a crossfade: no fade-in")
}

private func transitionAndMagnetChecks() {
    // 切点在转场上：A|B 有叠化（首尾相接，借余料）。一刀切要把声音分出去，画面的转场留着。
    let (base, a, _) = cutPair()
    var state = base
    state.mainClips[0].transitionAfter = .crossFade
    state.mainClips[0].transitionDuration = 0.5
    if let done = try? joinSound(state, after: a.id, .cut) {
        let out = done.outcome.outgoing.flatMap { done.state.clip(with: $0) }
        let into = done.outcome.incoming.flatMap { done.state.clip(with: $0) }
        check(out?.isAudioOnly == true && into?.isAudioOnly == true, "cut on a transition: both sounds are separated")
        checkNear(out?.timelineEnd, 4, "cut on a transition: the previous sound ends exactly on the cut")
        checkNear(into?.timelineStart, 4, "cut on a transition: the next sound starts exactly on the cut")
        checkEqual(done.state.mainClips[0].transitionAfter, .crossFade, "cut on a transition: the picture keeps its transition")
        checkEqual(done.outcome.cut.transition, .crossFade, "the cut knows it has a picture transition")
    } else { check(false, "cut on a transition works") }

    // 另一头有转场：B|C 叠化 0.5 秒（B 的尾料够）。A|B 叠着换要把 B 的声音分出去，B 的尾巴照它原来响的样子：借尾料到 8.5、渐出 0.5。
    var three = cutPair().state
    three.mainClips[1].transitionAfter = .crossFade
    three.mainClips[1].transitionDuration = 0.5
    three.mainClips.append(cutShot(cutFileC, 8, 4, source: 30))
    if let done = try? joinSound(three, after: three.mainClips[0].id, .crossfade, frames: 6) {
        let into = done.outcome.incoming.flatMap { done.state.clip(with: $0) }
        checkNear(into?.timelineEnd, 8.5, "separating B keeps its B|C transition sound: it still runs into C's crossfade")
        checkNear(into?.fadeOutDuration, 0.5, "…and still fades out over the transition")
        checkEqual(done.state.mainClips[2].isMuted, false, "C keeps its own sound and its transition fade-in")
    } else { check(false, "crossfade next to a transition works") }

    // 磁吸开着：A|B 叠化排成相叠（B 从 3.5 起），切点是叠的正中 3.75。叠着换 6 帧；V1 不动、磁吸不排。
    var packed = cutPair().state
    packed.mainMagnet = true
    packed.mainClips[0].transitionAfter = .crossFade
    packed.mainClips[0].transitionDuration = 0.5
    packed.mainClips[1].timelineStart = 3.5
    guard let done = try? joinSound(packed, after: packed.mainClips[0].id, .crossfade, frames: 6) else {
        return check(false, "crossfade on a magnet-packed transition works")
    }
    checkNear(done.outcome.cut.time, 3.75, "magnet: the cut is the middle of the overlap")
    checkNear(done.outcome.outgoing.flatMap { done.state.clip(with: $0) }?.timelineEnd, 4.0, "magnet: previous sound ends 6 frames after it")
    checkNear(done.outcome.incoming.flatMap { done.state.clip(with: $0) }?.timelineStart, 3.5, "magnet: next sound starts 6 frames before it")
    checkEqual(mainStarts(done.state), [0, 3.5], "magnet: V1 does not move")
    var settled = done.state
    settled.packMain()
    checkEqual(mainStarts(settled), [0, 3.5], "magnet: packing V1 again changes nothing (the join never touches V1's layout)")
    var followed = done.state
    let report = TimelineLinkage.follow(from: packed, to: &followed, deletesContent: false)
    check(report.isEmpty && followed == done.state, "linkage on: the join moves no V1 picture, so nothing else follows")
}

private func sameFileAndUpperTrackChecks() {
    // 两边是同一素材、接着的两截（文件 A 的 10–14、14–18 秒）：叠出来的两段在同一刻读文件的同一秒，叠着换听不出接缝。
    var state = TimelineState()
    let a = cutShot(cutFileA, 0, 4, source: 10)
    let b = cutShot(cutFileA, 4, 4, source: 14)
    state.mainClips = [a, b]
    if let done = try? joinSound(state, after: a.id, .crossfade, frames: 6),
       let out = done.outcome.outgoing.flatMap({ done.state.clip(with: $0) }),
       let into = done.outcome.incoming.flatMap({ done.state.clip(with: $0) }) {
        checkNear(out.sourceTime(atTimeline: 3.9), into.sourceTime(atTimeline: 3.9), "same file: both read the same second at the same moment")
        checkNear(out.sourceStart + out.sourceDuration, 14.25, "same file: the outgoing sound reads on into the next shot's footage")
        check(out.linkGroup != into.linkGroup, "same file: each sound has its own link group")
        checkEqual(CutSoundCut.separatedSound(of: done.state.clip(with: b.id)!, in: done.state)?.id, into.id,
                   "same file: the next picture's sound is found back as its own, not the other one")
    } else { check(false, "crossfade between two pieces of one file works") }

    // 上层轨（V2）上的一刀，画面自己带着声音：先进 6 帧；V1 不动。给分出去的声音的 id 也认得出是哪一刀。
    var upper = TimelineState()
    upper.mainClips = [cutShot(cutFileC, 0, 10, source: 0)]
    let p1 = cutShot(cutFileA, 1, 2, source: 5)
    let p2 = cutShot(cutFileB, 3, 2, source: 7)
    upper.overlayTracks = [EditLane(clips: [p1, p2])]
    guard let done = try? joinSound(upper, after: p1.id, .lead, frames: 6) else { return check(false, "a sound join on V2 works") }
    checkNear(done.outcome.incoming.flatMap { done.state.clip(with: $0) }?.timelineStart, 2.75, "V2: the next sound starts 6 frames early")
    checkEqual(done.state.mainClips[0].isMuted, false, "V2: V1 is left alone")
    checkEqual(done.outcome.cut.track, .overlay(0), "V2: the cut is on V2")
    if let sound = done.outcome.incoming, let again = try? CutSoundCut.after(sound, in: done.state) {
        checkEqual(again.outgoing.id, p2.id, "a separated sound as after_clip_id means the cut after its own picture")
    }
    checkThrows("there is no cut after the last clip") { _ = try CutSoundCut.after(p2.id, in: upper) }
    var gap = cutPair().state
    gap.mainClips[1].timelineStart = 4.5
    checkThrows("a gap is not a cut") { _ = try CutSoundCut.after(gap.mainClips[0].id, in: gap) }
    var hidden = cutPair().state
    hidden.mainClips[1].isHidden = true
    checkThrows("a hidden side is refused") { _ = try CutSoundCut.after(hidden.mainClips[0].id, in: hidden) }
    var music = cutPair().state
    let loose = audioClip(0, 5)
    music.audioTracks = [EditLane(clips: [loose])]
    checkThrows("a sound with no picture is not a picture cut") { _ = try CutSoundCut.after(loose.id, in: music) }
}

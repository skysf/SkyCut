import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 1. oracle：已知频率和电平的正弦、已知时刻的脉冲、一条 0.56 秒的音效、EBU Tech 3341 的响度测试信号。

/// 四个频段各放一个正弦（振幅 0.25：RMS −15.05 dBFS）：那一段 = 整体电平，别的段至少低 40 dB，四段加起来 = 整体（Parseval）。
func checkBandOracle() {
    group("1a. 频段 oracle：正弦落在它那一段，别的段压得够低（24 / 30 / 60 fps）")
    let expected = 20 * log10(0.25 / 2.0.squareRoot())
    let cases: [(frequency: Double, band: Int, fps: ProjectFrameRate)] = [
        (100, 0, .fps24), (500, 1, .fps24), (1500, 2, .fps24), (6000, 3, .fps24), (500, 1, .fps60), (1500, 2, .fps30)
    ]
    for (frequency, band, fps) in cases {
        let tone = sineWAV("band-\(Int(frequency))-\(fps.fps).wav", frequency: frequency, amplitude: 0.25, seconds: 2)
        var state = baseState(fps: fps)
        state.audioTracks = [EditLane(clips: [audioClip(tone, at: 0, duration: 2)])]
        guard let result = measure(state), let layer = result.layers.first else { continue }
        let label = "\(Int(frequency)) Hz @ \(fps.fps) fps"
        check(result.frames.count == 2 * fps.fps, "\(label)：2 秒正好 \(2 * fps.fps) 帧（得到 \(result.frames.count)）")
        // 头尾两帧的窗伸出时间线，汉宁窗被截断、旁瓣漏得多；只看中间的帧。
        let interior = layer.frames.dropFirst(2).dropLast(2)
        let overall = decibels(interior.reduce(0) { $0 + $1.meanSquare } / Double(interior.count))
        check(abs(overall - expected) < 0.02, "\(label)：整体电平 = \(expected) dB（得到 \(overall)）")
        var worstOwn = 0.0, worstLeak = -200.0, worstSum = 0.0
        for frame in interior {
            let own = decibels(frame.bands[band])
            worstOwn = max(worstOwn, abs(own - expected))
            for other in 0..<4 where other != band { worstLeak = max(worstLeak, decibels(frame.bands[other]) - expected) }
            let sum = decibels(frame.bands[0] + frame.bands[1] + frame.bands[2] + frame.bands[3])
            worstSum = max(worstSum, abs(sum - decibels(frame.meanSquare)))
        }
        check(worstOwn < 0.1, "\(label)：每一帧它那一段的电平 = \(expected) dB（最差差 \(worstOwn) dB）")
        check(worstLeak < -40, "\(label)：别的段比它低 40 dB 以上（最差 \(worstLeak) dB）")
        check(worstSum < 0.2, "\(label)：四段加起来 = 这一帧的电平（Parseval，最差差 \(worstSum) dB）")
    }
}

/// 一个采样的脉冲：峰值落在那个采样上，最响的帧就是它那一帧；频段最响的也是那一帧（脉冲在帧中间附近）。
func checkPulseOracle() {
    group("1b. 脉冲 oracle：峰值到采样、最响的帧到帧（24 / 30 / 60 fps）")
    let at = 59_256    // 1.2345 秒：24 fps 第 29 帧的中间附近
    let pulse = writeWAV("pulse.wav", seconds: 3) { frame, _ in frame == at ? 0.9 : 0 }
    for fps in [ProjectFrameRate.fps24, .fps30, .fps60] {
        var state = baseState(fps: fps)
        state.audioTracks = [EditLane(clips: [audioClip(pulse, at: 0, duration: 3)])]
        guard let result = measure(state), let layer = result.layers.first else { continue }
        let grid = result.grid
        let frame = grid.frame(ofSample: Int64(at))
        check(layer.peakSample == Int64(at) && result.peakSample == Int64(at),
              "\(fps.fps) fps：峰值落在第 \(at) 个采样（层 \(String(describing: layer.peakSample))、混音 \(String(describing: result.peakSample))）")
        let loudest = layer.frames.indices.max { layer.frames[$0].meanSquare < layer.frames[$1].meanSquare } ?? -1
        check(loudest == frame, "\(fps.fps) fps：最响的帧是脉冲那一帧（第 \(frame) 帧，得到 \(loudest)）")
        let mixLoudest = result.mix.indices.max { result.mix[$0].meanSquare < result.mix[$1].meanSquare } ?? -1
        check(mixLoudest == frame, "\(fps.fps) fps：混音最响的帧也是它（得到 \(mixLoudest)）")
        check(abs(layer.peak - 0.9) < 1e-6, "\(fps.fps) fps：峰值照实（得到 \(layer.peak)）")
        if fps == .fps24 {
            let bands = layer.frames.map { $0.bands[0] + $0.bands[1] + $0.bands[2] + $0.bands[3] }
            let bandLoudest = bands.indices.max { bands[$0] < bands[$1] } ?? -1
            check(bandLoudest == frame, "24 fps：频段最响的也是脉冲那一帧（得到 \(bandLoudest)）")
        }
    }
}

/// 一条 0.56 秒的音效：底子轻、中间 40 ms 很响（时间线 2.25–2.29 秒，24 fps 第 54 帧里）。最响处（loudest_at）正好是那一帧的帧头。
func checkSoundEffect() {
    group("1c. 0.56 秒的音效：最响处精确到帧")
    let hit = writeWAV("hit.wav", seconds: 0.56) { frame, _ in
        let seconds = Double(frame) / 48_000
        let amplitude: Float = (0.25 ..< 0.29).contains(seconds) ? 0.6 : 0.1
        return amplitude * Float(sin(2 * Double.pi * 440 * seconds))
    }
    let music = sineWAV("bed.wav", frequency: 220, amplitude: 0.2, seconds: 4)
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(music, at: 0, duration: 4)]), EditLane(clips: [audioClip(hit, at: 2, duration: 0.56)])]
    guard let result = measure(state), result.layers.count == 2 else { check(false, "两层没量出来"); return }
    let layer = result.layers[1]
    let loudest = layer.frames.indices.max { layer.frames[$0].meanSquare < layer.frames[$1].meanSquare } ?? -1
    check(loudest == 54, "音效那一层最响的是第 54 帧（2.25 秒；得到 \(loudest)）")
    let plan = AIListenMixPlan(grid: result.grid, frames: result.frames, layers: result.layers.map(\.layer), perFrame: false,
                               silenceDB: -45, minSilence: 0.5, duration: state.duration)
    let report = AIListenMixReport.json(result, plan: plan)
    let reported = report["layers"]?.arrayValue?[1].objectValue?["loudest_at"]?.doubleValue
    check(reported == 2.25, "listen 报的 loudest_at = 2.25（帧头；得到 \(String(describing: reported))）")
    let mixOver = report["mix"]?.objectValue?["over"]?.arrayValue ?? []
    check(mixOver.isEmpty, "0.2 + 0.6 没过 −1 dBFS：over 是空的（得到 \(mixOver.count) 段）")
    // clip_id 的问法：量这一段的那几秒，默认分成它那条轨和 rest。
    let ids = AIShortIDs(state: state)
    guard let hitID = state.audioTracks[1].clips.first?.id else { return }
    let args = AIToolArguments(["mix": true, "clip_id": .string(ids.short(hitID))])
    let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
    guard let clipPlan = try? AIListenMixPlan.make(args, state: state, config: config, from: nil, to: nil, silenceDB: -45, minSilence: 0.5)
    else { check(false, "clip_id 的问法没做成计划"); return }
    check(clipPlan.frames == 48 ..< 62, "clip_id：量 2.0–2.56 秒那几帧（48..<62，得到 \(clipPlan.frames)）")
    check(clipPlan.layers.map(\.name) == ["A2", "rest"], "clip_id：默认两层，它那条轨和 rest（得到 \(clipPlan.layers.map(\.name))）")
}

/// EBU Tech 3341 的 1 kHz 立体声正弦：−23 dBFS → 瞬时、短时、整体都是 −23.0 LUFS；−33 → −33。
func checkLoudnessOracle() {
    group("1d. 响度 oracle（EBU Tech 3341 第 1、2 例）：瞬时 / 短时 / 整体")
    for level in [-23.0, -33.0] {
        let tone = sineWAV("ebu\(Int(-level)).wav", frequency: 1000, amplitude: Float(pow(10, level / 20)), seconds: 6)
        var state = baseState()
        state.audioTracks = [EditLane(clips: [audioClip(tone, at: 0, duration: 6)])]
        guard let result = measure(state) else { continue }
        let integrated = result.levels.loudnessLUFS ?? -99
        check(abs(integrated - level) < 0.1, "\(level) dBFS：整体响度 \(level) LUFS（得到 \(integrated)）")
        let momentary = result.mix.dropFirst(12).compactMap(\.momentaryLUFS)    // 0.5 秒以后窗里全是声音
        check(momentary.count == 132 && momentary.allSatisfy { abs($0 - level) < 0.1 },
              "\(level) dBFS：0.5 秒以后每一帧的瞬时响度 = \(level)（\(momentary.count) 帧，范围 \(momentary.min() ?? 0)…\(momentary.max() ?? 0)）")
        let shortTerm = result.mix.dropFirst(75).compactMap(\.shortTermLUFS)    // 3.1 秒以后
        check(shortTerm.count == 69 && shortTerm.allSatisfy { abs($0 - level) < 0.1 },
              "\(level) dBFS：3 秒以后每一帧的短时响度 = \(level)（\(shortTerm.count) 帧）")
        let early = result.mix[4].momentaryLUFS ?? -99
        check(early < level - 2, "\(level) dBFS：0.2 秒处窗里一半是时间线开头之前（静音），瞬时响度低一截（得到 \(early)）")
    }
}

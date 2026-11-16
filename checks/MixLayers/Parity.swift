import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 2. 和导出对账：整条量 = 导出报的；每层加起来 = 混音；只量一段 = 整段里那几段；单声道的人声 = 成片里的电平。

/// 会过线的时间线：V1 一段（单声道，轨道推子 0.8）、A1 渐入渐出 + 音量曲线、A2 和 A1 叠起来过 −1 dBFS，总推子 0.9。
/// `scene` 给 A1 挂一个声音场景（余音越过段尾）。
func loudTimeline(scene: Bool = false) -> TimelineState {
    let voice = writeWAV("parity-voice.wav", channels: 1, seconds: 4) { frame, _ in
        var noise = CheckNoise(seed: UInt64(frame))
        return 0.3 * Float(sin(2 * Double.pi * 300 * Double(frame) / 48_000)) + noise.next(0.05)
    }
    let first = sineWAV("parity-a.wav", frequency: 440, amplitude: 0.6, seconds: 4)
    let second = sineWAV("parity-b.wav", frequency: 660, amplitude: 0.6, seconds: 3)
    var state = baseState()
    state.mainClips = [pictureClip(voice, at: 0, duration: 4)]
    state.mainVolume = 0.8
    var lead = audioClip(first, at: 0.5, duration: 4)
    lead.fadeInDuration = 0.5
    lead.fadeOutDuration = 1
    lead.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 1, value: 0), Keyframe(time: 2, value: -6), Keyframe(time: 3, value: 0)])
    if scene { lead.soundScene = SoundScene(kind: .room, amount: 0.6, first: 0.5, second: 0.5) }
    state.audioTracks = [EditLane(clips: [lead]), EditLane(clips: [audioClip(second, at: 1.5, duration: 3)])]
    state.masterVolume = 0.9
    return state
}

func checkExportParity() async {
    group("2a. 整条时间线：峰值、写出去的峰值、过线、压得最深、整体响度 = 导出报的（逐位）")
    for (label, state) in [("无场景", loudTimeline()), ("挂了场景", loudTimeline(scene: true))] {
        let file = root.appendingPathComponent("parity-\(label).f32")
        let outcome = try? await ExportAudioMixdown.render(state: state, duration: state.duration, to: file)
        guard case .written(let exported)? = outcome, let result = measure(state) else {
            check(false, "\(label)：导出的混音或按层量没做出来"); continue
        }
        let measured = result.levels
        check(exported.isLimited, "\(label)：这条时间线真的过线了（限幅器有活干，对账才有意义；压了 \(exported.limitedFrames) 帧）")
        check(measured.peak == exported.peak, "\(label)：限幅前的峰值一样（\(measured.peak) vs 导出 \(exported.peak)）")
        check(measured.outputPeak == exported.outputPeak, "\(label)：写出去的峰值一样（\(measured.outputPeak) vs \(exported.outputPeak)）")
        check(measured.limitedFrames == exported.limitedFrames, "\(label)：过线的帧数一样（\(measured.limitedFrames) vs \(exported.limitedFrames)）")
        check(measured.maxReductionDB == exported.maxReductionDB, "\(label)：压得最深一样（\(measured.maxReductionDB) vs \(exported.maxReductionDB)）")
        check(measured.loudnessLUFS == exported.loudnessLUFS,
              "\(label)：整体响度一样（\(String(describing: measured.loudnessLUFS)) vs \(String(describing: exported.loudnessLUFS))）")
        try? FileManager.default.removeItem(at: file)
    }
}

func checkLayersAddUp() {
    group("2b. 每层加起来 = 整条混音（限幅之前）；限幅器没动的帧，写出去的 = 进来的")
    let state = loudTimeline()
    var worst: Float = 0
    var blocks = 0
    guard let result = measure(state, observe: { block in
        blocks += 1
        for index in 0 ..< block.frames * 2 {
            let sum = block.layers.reduce(Float(0)) { $0 + $1[index] }
            worst = max(worst, abs(sum - block.mix[index]))
        }
    }) else { return }
    check(blocks > 0 && result.layers.count == 3, "三层（V1、A1、A2）都渲了（\(result.layers.count) 层、\(blocks) 块）")
    check(worst < 1e-5, "每个采样：三层相加 = 混音（最大差 \(worst)）")
    let untouched = result.mix.filter { $0.minGain == 1 && $0.peak > 0 }
    check(!untouched.isEmpty && untouched.allSatisfy { $0.outputPeak == $0.peak },
          "限幅器没动的 \(untouched.count) 帧：写出去的峰值 = 进来的")
    let pressed = result.mix.filter { $0.overSamples > 0 }
    check(!pressed.isEmpty && pressed.allSatisfy { $0.minGain < 1 && $0.outputPeak <= 0.891 + 1e-4 },
          "过线的 \(pressed.count) 帧：限幅器压了、写出去的不超过 −1 dBFS")
}

/// 只量中间一段（前面多渲几秒接上限幅器、K 加权和 3 秒的窗）= 整段量出来的同样那几帧。
func checkWindowMatchesWhole() {
    group("2c. 只量 29–44 秒、43–49 秒 = 整段量里的同样那几帧；过线标出时刻")
    let music = writeWAV("long-music.wav", seconds: 50) { frame, channel in
        let t = Double(frame) / 48_000
        let swell = 0.6 + 0.4 * sin(2 * Double.pi * t / 7)
        return Float(swell * (0.2 * sin(2 * Double.pi * 220 * t) + 0.1 * sin(2 * Double.pi * (330 + Double(channel)) * t)))
    }
    // 重击自己的峰值就过 −1 dBFS（0.95 × 第一个波峰 ≈ 0.93），不管底下的音乐此刻多响。
    let hit = writeWAV("long-hit.wav", seconds: 0.3) { frame, _ in
        0.95 * Float(exp(-Double(frame) / 6000) * sin(2 * Double.pi * 90 * Double(frame) / 48_000))
    }
    let voice = writeWAV("long-voice.wav", channels: 1, seconds: 5) { frame, _ in
        var noise = CheckNoise(seed: UInt64(frame) &* 7)
        return noise.next(0.2)
    }
    var state = baseState()
    state.audioTracks = [
        EditLane(clips: [audioClip(music, at: 0, duration: 50)]),
        EditLane(clips: [audioClip(hit, at: 31, duration: 0.3), audioClip(hit, at: 40.5, duration: 0.3)]),
        EditLane(clips: [audioClip(voice, at: 43.5, duration: 5)])
    ]
    guard let whole = measure(state) else { return }
    for (from, to) in [(29.0, 44.0), (43.0, 49.0)] {
        guard let part = measure(state, from: from, to: to) else { continue }
        let offset = part.frames.lowerBound - whole.frames.lowerBound
        let same = Array(whole.mix[offset ..< offset + part.frames.count])
        var worstLevel = 0.0, worstLoudness = 0.0, worstGain: Float = 0, exactPeaks = true
        for (a, b) in zip(part.mix, same) {
            worstLevel = max(worstLevel, abs(decibels(a.meanSquare) - decibels(b.meanSquare)))
            worstGain = max(worstGain, abs(a.minGain - b.minGain))
            exactPeaks = exactPeaks && a.peak == b.peak && a.overSamples == b.overSamples
            for (x, y) in [(a.momentaryLUFS, b.momentaryLUFS), (a.shortTermLUFS, b.shortTermLUFS)] {
                worstLoudness = max(worstLoudness, abs((x ?? -99) - (y ?? -99)))
            }
        }
        let label = "\(from)–\(to) 秒"
        check(part.frames == Int(from * 24) ..< Int(to * 24), "\(label)：量的就是这几帧（\(part.frames)）")
        check(worstLevel < 1e-4 && exactPeaks, "\(label)：每帧的电平、峰值、过线的采样数 = 整段量的（电平最大差 \(worstLevel) dB）")
        check(worstGain < 1e-5, "\(label)：每帧限幅器压了多少 = 整段量的（最大差 \(worstGain)）")
        check(worstLoudness < 0.01, "\(label)：每帧的瞬时 / 短时响度 = 整段量的（最大差 \(worstLoudness) LU）")
        var worstBand = 0.0
        for (layer, wholeLayer) in zip(part.layers, whole.layers) {
            for (a, b) in zip(layer.frames, wholeLayer.frames[offset ..< offset + part.frames.count]) {
                for band in 0..<4 where b.bands[band] > 1e-9 {
                    worstBand = max(worstBand, abs(decibels(a.bands[band]) - decibels(b.bands[band])))
                }
            }
        }
        check(worstBand < 1e-3, "\(label)：每层每帧的四个频段 = 整段量的（最大差 \(worstBand) dB）")
    }
    // 29–44 秒写给 AI 的：平均电平、峰值，过线的两下标出时刻（31.0、40.5 秒起的那几帧）。
    guard let part = measure(state, from: 29, to: 44) else { return }
    let plan = AIListenMixPlan(grid: part.grid, frames: part.frames, layers: part.layers.map(\.layer), perFrame: false,
                               silenceDB: -45, minSilence: 0.5, duration: state.duration)
    let mix = AIListenMixReport.json(part, plan: plan)["mix"]?.objectValue ?? [:]
    check(mix["level_db"]?.doubleValue != nil && (mix["peak_db"]?.doubleValue ?? -99) > -1, "29–44 秒：有平均电平、峰值过了 −1 dBFS")
    let over = mix["over"]?.arrayValue ?? []
    let starts = over.compactMap { $0["from"]?.doubleValue }
    check(starts.count == 2 && starts.first == 31 && starts.last == 40.5,
          "29–44 秒：过线的两下标在 31.0 和 40.5 秒起的帧上（得到 \(starts)）")
    check(over.allSatisfy { ($0["reduction_db"]?.doubleValue ?? 0) > 0 }, "过线的每一段都说了限幅器压了多少")
    check((mix["from"]?.doubleValue, mix["to"]?.doubleValue) == (29, 44), "结果写明量的是 29–44 秒")
    check(mix["peak_at"]?.doubleValue.map { (31 ..< 31.3).contains($0) || (40.5 ..< 40.8).contains($0) } == true,
          "峰值的时刻落在两下中的一下里（\(String(describing: mix["peak_at"])))")
}

/// 单声道的人声：量出来的电平 = 它在导出成片里的电平（真跑一遍导出、ffmpeg 编成 AAC 再解回来），也 = 素材 RMS × 增益。
/// 预览板工具从素材文件估的那种做法会偏 3 dB（铺成立体声时每声道 −3 dB、量的时候没算）；从引擎量就没有这件事。
func checkMonoVoiceMatchesExport() async {
    group("2d. 单声道人声：量出来的电平 = 导出成片里的电平")
    let voice = writeWAV("mono-voice.wav", channels: 1, seconds: 4) { frame, _ in
        var noise = CheckNoise(seed: UInt64(frame) &+ 99)
        return 0.25 * Float(sin(2 * Double.pi * 250 * Double(frame) / 48_000)) + noise.next(0.1)
    }
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(voice, at: 0.5, duration: 4, volume: 0.7)], volume: 0.8)]
    state.masterVolume = 0.9
    guard let result = measure(state), let layer = result.layers.first else { return }
    // 第 1–4 秒（第 24..<96 帧）：整段都是人声。
    let frames = layer.frames[24 ..< 96]
    let measured = decibels(frames.reduce(0) { $0 + $1.meanSquare } / Double(frames.count))
    var source = 0.0
    for frame in 24_000 ..< 168_000 {    // 素材的 0.5–3.5 秒 = 时间线 1–4 秒
        var noise = CheckNoise(seed: UInt64(frame) &+ 99)
        let value = 0.25 * sin(2 * Double.pi * 250 * Double(frame) / 48_000) + Double(noise.next(0.1))
        source += value * value
    }
    let expected = decibels(source / 144_000) + 20 * log10(0.7 * 0.8 * 0.9)
    check(abs(measured - expected) < 0.01, "按层量的电平 = 素材 RMS + 增益（\(measured) vs \(expected) dB）")
    let output = root.appendingPathComponent("mono-voice.m4a")
    guard let plan = try? await VideoEditExportGraph.plan(
        state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil,
        output: output, watermark: nil
    ) else { check(false, "导出的 plan() 失败"); return }
    defer { try? FileManager.default.removeItem(at: plan.workspace) }
    let (code, log) = run(ffmpegPath, plan.arguments)
    guard code == 0 else { check(false, "ffmpeg 导出失败：\(log.suffix(300))"); return }
    let decoded = root.appendingPathComponent("mono-voice.f32")
    run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-i", plan.tempOutput.path, "-vn", "-ac", "2", "-ar", "48000",
                     "-f", "f32le", decoded.path])
    guard let data = try? Data(contentsOf: decoded) else { check(false, "成片解不回来"); return }
    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard samples.count >= 192_000 * 2 else { check(false, "成片太短（\(samples.count / 2) 帧）"); return }
    let film = decibels(samples[96_000 ..< 384_000].reduce(0.0) { $0 + Double($1) * Double($1) } / 288_000)
    check(abs(measured - film) < 0.1, "按层量的电平 = 导出成片里的电平（\(measured) vs 成片 \(film) dB；AAC 一来一回 < 0.1 dB）")
}

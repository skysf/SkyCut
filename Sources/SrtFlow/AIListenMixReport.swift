import Foundation
import SrtFlowMCPKit

// MARK: - listen mix=true 的结果写给 AI（纯值）
//
// 管什么：MixMeasurement 量出来的每一帧 → AI 一次读得完的一份：先给摘要（整条混音和每层的电平、响度、峰值、最响处、过线的时刻），
// 逐帧的数只在 `frames=true` 时给、条数由 AIListenMixPlan 限住。口径：
// - 时间都是时间线秒、落在帧上（`loudest_at` = 最响那一帧的帧头；`peak_at` = 真峰值所在的那个采样，到采样）。
// - 电平（level_db）同 listen 的老口径：有声音的部分的 RMS（两个声道平均），静音帧（低于 silence_db）不进平均；
//   摘要的电平、峰值、静音、粗曲线都交给 AIAudioLevels 算（每帧当一个窗），和 listen clip_id 同一套规矩。
// - Every peak is a true peak (TruePeak, dBTP, the measure the export limiter holds; 2026-11-17). 混音的 peak_db 是**限幅之前**的
//   （= 导出报的 audio_peak_before_limiter_dbtp），output_peak_db 是限幅之后写出去的；响度（loudness_lufs、瞬时、短时）量的是**限幅之后**
//   真写进成片的（= 导出报的 audio_loudness_lufs）；over = 限幅之前真峰值超过限幅器上限（−1 dBTP）的那几帧，只报不拦。
// - 每层是它进总线时的样子（片段音量、曲线、渐变、场景、轨道推子、总推子都算上，限幅之前）。
// 不管什么：量（MixMeasurement）、参数（AIListenMixPlan）、任务（AIListenMix）。

enum AIListenMixReport {
    /// 过线的时刻最多列几段。
    static let maxOverRanges = 20
    /// 瞬时 / 短时响度没有声音时写成这个数（BS.1770 的绝对门限）。
    static let silentLUFS = ExportLoudnessMeter.absoluteGateLUFS

    static func json(_ result: MixMeasurement.Result, plan: AIListenMixPlan) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "mix": .object(mix(result, plan: plan)),
            "layers": .array(result.layers.map { .object(layer($0, result: result, plan: plan)) }),
            "note": .string(
                "Rendered by SkyCut's audio engine like the export. Layers are as they enter the master bus (clip volume, "
                    + "fades, scenes, track and master faders; before the limiter). Peaks are true peaks (dBTP). Mix peak_db is "
                    + "before the limiter; loudness is after it (as exported). over = above the -1 dBTP limiter ceiling: reported, not blocked."
            )
        ]
        if plan.perFrame { object["frames"] = .object(frames(result, plan: plan)) }
        return object
    }

    // MARK: 摘要

    private static func mix(_ result: MixMeasurement.Result, plan: AIListenMixPlan) -> [String: JSONValue] {
        let windows = result.mix.indices.map {
            window(result, index: $0, meanSquare: result.mix[$0].meanSquare, peak: result.mix[$0].peak, plan: plan)
        }
        var object = summary(windows, result: result, plan: plan, peakSample: result.peakSample)
        object["from"] = AIFormat.seconds(result.grid.seconds(ofFrame: result.frames.lowerBound))
        object["to"] = AIFormat.seconds(frameEnd(result.frames.upperBound - 1, result: result, plan: plan))
        object["frame_rate"] = .number(Double(result.grid.fps))
        if let loudness = result.levels.loudnessLUFS { object["loudness_lufs"] = tenths(loudness) }
        if let at = loudestWindow(result, \.momentaryLUFS, seconds: MixBusMeter.momentarySeconds, plan: plan) { object["max_momentary"] = at }
        if let at = loudestWindow(result, \.shortTermLUFS, seconds: MixBusMeter.shortTermSeconds, plan: plan) { object["max_short_term"] = at }
        let over = overRanges(result, plan: plan)
        object["over"] = .array(Array(over.prefix(maxOverRanges)))
        if over.count > maxOverRanges { object["more_over"] = .number(Double(over.count - maxOverRanges)) }
        if result.levels.isLimited {
            object["limited_seconds"] = .number((result.levels.limitedSeconds * 1000).rounded() / 1000)
            object["max_reduction_db"] = tenths(result.levels.maxReductionDB)
        }
        object["output_peak_db"] = tenths(peakDecibels(Double(result.levels.outputPeak)))
        if let curve = AIAudioLevels.curve(windows) {
            object["curve"] = ["from": AIFormat.seconds(curve.from), "step": AIFormat.seconds(curve.step),
                               "db": .array(curve.decibels.map { .number(Double($0)) })]
        }
        return object
    }

    private static func layer(_ layer: MixMeasurement.Layer, result: MixMeasurement.Result, plan: AIListenMixPlan) -> [String: JSONValue] {
        let windows = layer.frames.indices.map {
            window(result, index: $0, meanSquare: layer.frames[$0].meanSquare, peak: layer.frames[$0].peak, plan: plan)
        }
        var object: [String: JSONValue] = ["name": .string(layer.layer.name)]
        object.merge(summary(windows, result: result, plan: plan, peakSample: layer.peakSample)) { _, new in new }
        if let loudness = layer.loudnessLUFS { object["loudness_lufs"] = tenths(loudness) }
        // 频段：有声音的帧按功率平均。
        let audible = layer.frames.filter { decibels($0.meanSquare) >= plan.silenceDB }
        if !audible.isEmpty {
            let mean = audible.reduce(SIMD4<Double>.zero) { $0 + $1.bands } / Double(audible.count)
            object["bands_db"] = .object(Dictionary(uniqueKeysWithValues: zip(bandNames, (0..<4).map { tenths(decibels(mean[$0])) })))
        }
        return object
    }

    /// 频段的名字：<300、300–800、800–3000、>3000 Hz。
    static let bandNames = ["low", "low_mid", "high_mid", "high"]

    /// 电平、峰值、静音、最响的那一帧、最响的采样。
    private static func summary(
        _ windows: [AIAudioLevels.Window], result: MixMeasurement.Result, plan: AIListenMixPlan, peakSample: Int64?
    ) -> [String: JSONValue] {
        let report = AIAudioLevels.report(windows, silenceDB: plan.silenceDB, minSilence: plan.minSilence)
        // 峰值不封顶（AudioGain 的 dB 封在 +6：几层叠起来可以更响，要照实报）。
        let peak = windows.map(\.peak).max() ?? 0
        var object: [String: JSONValue] = ["peak_db": tenths(peakDecibels(peak))]
        object["level_db"] = report.levelDB.map(tenths) ?? "silent"
        if report.silentSeconds > 0 { object["silent_seconds"] = AIFormat.seconds(report.silentSeconds) }
        if let loudest = windows.indices.max(by: { windows[$0].meanSquare < windows[$1].meanSquare }), windows[loudest].meanSquare > 0 {
            object["loudest_at"] = AIFormat.seconds(windows[loudest].start)
        }
        if let peakSample, peak > 0 {
            object["peak_at"] = AIFormat.seconds(Double(peakSample) / Double(result.grid.sampleRate))
        }
        return object
    }

    /// 真峰值（线性）→ dBTP：不封顶，−60 以下当静音（TruePeak.decibels）。
    private static func peakDecibels(_ linear: Double) -> Double { TruePeak.decibels(Float(linear)) }

    /// 瞬时 / 短时响度最大的那一刻：量的那个窗（窗尾 = 那一帧的帧尾）。
    private static func loudestWindow(
        _ result: MixMeasurement.Result, _ key: KeyPath<MixBusMeter.Frame, Double?>, seconds: Double, plan: AIListenMixPlan
    ) -> JSONValue? {
        var best: (index: Int, value: Double)?
        for (index, frame) in result.mix.enumerated() {
            if let value = frame[keyPath: key], value > (best?.value ?? -.infinity) { best = (index, value) }
        }
        guard let best else { return nil }
        let end = frameEnd(result.frames.lowerBound + best.index, result: result, plan: plan)
        return ["lufs": tenths(best.value), "from": AIFormat.seconds(max(0, end - seconds)), "to": AIFormat.seconds(end)]
    }

    /// 限幅之前过了线的那几帧，连着的并成一段：从哪到哪、最响多少、限幅器压了多少。
    private static func overRanges(_ result: MixMeasurement.Result, plan: AIListenMixPlan) -> [JSONValue] {
        var ranges: [JSONValue] = []
        var index = 0
        while index < result.mix.count {
            guard result.mix[index].overSamples > 0 else { index += 1; continue }
            var end = index
            while end + 1 < result.mix.count, result.mix[end + 1].overSamples > 0 { end += 1 }
            let span = result.mix[index...end]
            let peak = span.map(\.peak).max() ?? 0
            let gain = span.map(\.minGain).min() ?? 1
            ranges.append([
                "from": AIFormat.seconds(result.grid.seconds(ofFrame: result.frames.lowerBound + index)),
                "to": AIFormat.seconds(frameEnd(result.frames.lowerBound + end, result: result, plan: plan)),
                "peak_db": tenths(peakDecibels(Double(peak))),
                "reduction_db": tenths(-20 * log10(Double(max(gain, 1e-9))))
            ])
            index = end + 1
        }
        return ranges
    }

    // MARK: 逐帧

    private static func frames(_ result: MixMeasurement.Result, plan: AIListenMixPlan) -> [String: JSONValue] {
        let mix = result.mix
        var layers: [String: JSONValue] = [:]
        for layer in result.layers {
            var arrays: [String: JSONValue] = ["db": whole(layer.frames.map { decibels($0.meanSquare) })]
            for (band, name) in bandNames.enumerated() { arrays[name] = whole(layer.frames.map { decibels($0.bands[band]) }) }
            layers[layer.layer.name] = .object(arrays)
        }
        return [
            "from": AIFormat.seconds(result.grid.seconds(ofFrame: result.frames.lowerBound)),
            "fps": .number(Double(result.grid.fps)), "count": .number(Double(result.frames.count)),
            "mix": [
                "db": whole(mix.map { decibels($0.meanSquare) }),
                "peak_db": .array(mix.map { tenths(peakDecibels(Double($0.peak))) }),
                "momentary_lufs": whole(mix.map { $0.momentaryLUFS.map { max($0, silentLUFS) } ?? silentLUFS }),
                "reduction_db": .array(mix.map { tenths(-20 * log10(Double(max($0.minGain, 1e-9)))) })
            ],
            "layers": .object(layers)
        ]
    }

    // MARK: 小工具

    private static func window(
        _ result: MixMeasurement.Result, index: Int, meanSquare: Double, peak: Float, plan: AIListenMixPlan
    ) -> AIAudioLevels.Window {
        let frame = result.frames.lowerBound + index
        return AIAudioLevels.Window(
            start: result.grid.seconds(ofFrame: frame), end: frameEnd(frame, result: result, plan: plan),
            meanSquare: meanSquare, peak: Double(peak)
        )
    }

    /// 第 `frame` 帧的帧尾（秒），收在时间线里。
    private static func frameEnd(_ frame: Int, result: MixMeasurement.Result, plan: AIListenMixPlan) -> Double {
        min(result.grid.seconds(ofFrame: frame + 1), plan.duration)
    }

    /// 均方 → dB（AudioGain：−60 就是静音或更轻）。
    private static func decibels(_ meanSquare: Double) -> Double { AudioGain.decibels(fromLinear: meanSquare.squareRoot()) }

    private static func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }

    /// 逐帧的数取整到 dB（一次回几千个，小数位不值那几个字）。
    private static func whole(_ values: [Double]) -> JSONValue { .array(values.map { .number($0.rounded()) }) }
}

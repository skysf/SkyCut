import Foundation

// MARK: - 整条混音每一帧多响：过没过线、限幅器压了多少、瞬时 / 短时 / 整体响度（流式）
//
// 管什么：AudioStemRender 渲出来的整条混音（总线上的、限幅之前的交错立体声 f32）一块一块喂进来，按工程帧率切帧：
// - **限幅之前**（总线上）：每帧的均方（两个声道平均）、采样峰值、有几个采样帧过了线（限幅器的上限 −1 dBFS）；
// - **过一遍和成片同样的限幅器**（ExportPeakLimiter，同样的参数，`recordsGains` 记下每帧乘了多少）：每帧压得最深的增益、
//   写出去的峰值；
// - **限幅之后**（真写进成片的）：K 加权（AudioKWeighting，和成片同一套系数）的瞬时（400 ms）、短时（3 s）响度，量在每帧的末尾
//  （EBU Tech 3341 的两个窗，窗按采样算、不按帧凑）；量的范围里的整体响度喂 ExportLoudnessMeter（成片同一个门限算法）。
// 整条时间线从 0 量到结尾时，喂进限幅器和响度表的就是导出写进 f32 的那一串采样，`levels` 和导出报的
//（`ExportAudioMixdown.Levels`：限幅前的峰值、写出去的峰值、过线的帧数、压得最深、整体响度）逐位一样。
// 只量中间一段时，前面多渲的那几秒（MixMeasurement 的 preroll）让限幅器、K 加权和 3 秒的窗进到和整段渲一样的状态，
// 只有量的范围里的帧才算数。
// 不管什么：渲（AudioStemRender）、每层的频段（MixBandMeter）、写给 AI（AIListenMix）。

final class MixBusMeter {
    /// 一帧的量。
    struct Frame: Sendable, Equatable {
        /// 限幅之前的均方（两个声道平均；只算这一帧在时间线里的那部分）。
        var meanSquare: Double = 0
        /// 限幅之前的采样峰值（线性）。
        var peak: Float = 0
        /// 限幅之前过了线（限幅器的上限）的采样帧数。
        var overSamples = 0
        /// 限幅器在这一帧里乘得最小的那一下（1 = 没压）。
        var minGain: Float = 1
        /// 限幅之后的采样峰值。
        var outputPeak: Float = 0
        /// 这一帧末尾的瞬时响度（400 ms，K 加权，限幅之后；LUFS）；全静是 nil。
        var momentaryLUFS: Double?
        /// 这一帧末尾的短时响度（3 s）。
        var shortTermLUFS: Double?
    }

    static let momentarySeconds = 0.4
    static let shortTermSeconds = 3.0

    let grid: MixFrameGrid
    let frameRange: Range<Int>
    /// 时间线的尽头（采样）。
    let limit: Int64
    /// 从时间线的第几个采样开始喂（前面多渲的那几秒也算，限幅器和 K 加权要从这儿起步）。
    let renderStart: Int64
    /// 过线 = 超过限幅器的上限（−1 dBFS，同成片）。
    let ceiling: Float
    private(set) var frames: [Frame]
    /// 量的范围里限幅之前最响的采样（线性）和它在时间线的第几个采样。
    private(set) var peak: Float = 0
    private(set) var peakSample: Int64?

    private var limiter: ExportPeakLimiter
    private var loudness = ExportLoudnessMeter(channels: 2)
    private var weighting = [AudioKWeighting(), AudioKWeighting()]
    /// 每帧限幅之前的平方和（两个声道加起来），帧量完时折成均方。
    private var sums: [Double]
    /// K 加权功率的前缀和（从 renderStart 起），只留最近 3 秒 + 1 个：瞬时 / 短时响度 = 两个前缀和之差 ÷ 窗长。
    private var prefix: [Double]
    private var prefixTotal = 0.0
    /// 最新的前缀和在环的哪一格（= 写出去的采样数 mod 环长）。
    private var prefixSlot = 0
    /// 限幅器写出去了几个采样（从 renderStart 起）。
    private var emitted: Int64 = 0
    /// 跨块的那一帧到目前为止压得最深、最响（帧量完才写进 `frames`）。
    private var pendingGain: Float = 1
    private var pendingPeak: Float = 0
    /// 限幅之后正走到哪一帧（下标、帧尾）。
    private var outputFrame: Int
    private var outputFrameEnd: Int64
    private var limited: [Float] = []

    init(grid: MixFrameGrid, frames: Range<Int>, limit: Int64, renderStart: Int64) {
        self.grid = grid
        frameRange = frames
        self.limit = limit
        self.renderStart = renderStart
        // 和成片写 f32 那一步同样的参数（ExportAudioMixdown 的 FrameSink）。
        limiter = ExportPeakLimiter(channels: 2, sampleRate: grid.sampleRate)
        limiter.recordsGains = true
        ceiling = limiter.ceiling
        self.frames = [Frame](repeating: Frame(), count: frames.count)
        sums = [Double](repeating: 0, count: frames.count)
        prefix = [Double](repeating: 0, count: Int(Self.shortTermSeconds * Double(grid.sampleRate)) + 1)
        outputFrame = frames.lowerBound
        outputFrameEnd = min(grid.start(ofFrame: frames.lowerBound + 1), limit)
    }

    /// 量的范围（采样）：第一帧的头到最后一帧的尾，收在时间线里。
    var measuredSamples: Range<Int64> {
        let lower = grid.start(ofFrame: frameRange.lowerBound)
        return lower ..< max(lower, min(grid.start(ofFrame: frameRange.upperBound), limit))
    }

    /// 渲出来的一块整条混音（交错立体声、限幅之前），从时间线的第 `position` 个采样起；要一块接一块地喂。
    func add(_ block: UnsafeBufferPointer<Float>, at position: Int64, frames count: Int) {
        measureInput(block, at: position, frames: count)
        limited.removeAll(keepingCapacity: true)
        limiter.process(block, frames: count, into: &limited)
        consumeOutput()
    }

    /// 渲完了。渲到了时间线的尽头就照成片那样把限幅器的延迟冲干净（结尾那 5 ms 的输出才算得出来）。
    func finish(reachedEnd: Bool) {
        guard reachedEnd else { return }
        limited.removeAll(keepingCapacity: true)
        limiter.flush(into: &limited)
        consumeOutput()
    }

    /// 量的范围里的电平，口径同导出（`ExportAudioMixdown.Levels`）。
    var levels: ExportAudioMixdown.Levels {
        let minGain = frames.map(\.minGain).min() ?? 1
        return ExportAudioMixdown.Levels(
            peak: peak, outputPeak: frames.map(\.outputPeak).max() ?? 0,
            limitedFrames: frames.reduce(0) { $0 + $1.overSamples },
            maxReductionDB: -20 * log10(Double(max(minGain, 1e-9))), loudnessLUFS: loudness.integratedLUFS
        )
    }

    // MARK: 限幅之前

    private func measureInput(_ block: UnsafeBufferPointer<Float>, at position: Int64, frames count: Int) {
        let measured = measuredSamples
        let from = max(position, measured.lowerBound), to = min(position + Int64(count), measured.upperBound)
        guard to > from else { return }
        var frame = grid.frame(ofSample: from)
        var start = from
        while start < to {
            let frameStart = grid.start(ofFrame: frame), frameEnd = min(grid.start(ofFrame: frame + 1), limit)
            let end = min(to, frameEnd)
            let slot = frame - frameRange.lowerBound
            var sum = 0.0, over = 0, framePeak: Float = 0, peakAt = start
            for sample in start ..< end {
                let index = Int(sample - position) * 2
                let left = block[index], right = block[index + 1]
                sum += Double(left) * Double(left) + Double(right) * Double(right)
                let magnitude = max(abs(left), abs(right))
                if magnitude > ceiling { over += 1 }
                if magnitude > framePeak {
                    framePeak = magnitude
                    peakAt = sample
                }
            }
            sums[slot] += sum
            frames[slot].overSamples += over
            frames[slot].peak = max(frames[slot].peak, framePeak)
            if framePeak > peak {
                peak = framePeak
                peakSample = peakAt
            }
            if end == frameEnd { frames[slot].meanSquare = sums[slot] / Double(2 * (frameEnd - frameStart)) }
            start = end
            frame += 1
        }
    }

    // MARK: 限幅之后

    private func consumeOutput() {
        let gains = limiter.appliedGains
        limiter.appliedGains.removeAll(keepingCapacity: true)
        let measured = measuredSamples
        let firstSample = renderStart + emitted
        let count = limited.count / 2
        let momentary = Int(Self.momentarySeconds * Double(grid.sampleRate))
        let shortTerm = prefix.count - 1
        // 逐采样的热循环：滤波器、前缀和、这一帧压得最深 / 最响都挪到局部变量里，跑完写回。
        var leftFilter = weighting[0], rightFilter = weighting[1]
        var total = prefixTotal, slot = prefixSlot
        var frameGain = pendingGain, framePeak = pendingPeak
        for index in 0 ..< count {
            let sample = firstSample + Int64(index)
            let left = limited[2 * index], right = limited[2 * index + 1]
            let weightedLeft = leftFilter.process(Double(left)), weightedRight = rightFilter.process(Double(right))
            total += weightedLeft * weightedLeft + weightedRight * weightedRight
            slot += 1
            if slot == prefix.count { slot = 0 }
            prefix[slot] = total
            guard measured.contains(sample) else { continue }
            frameGain = min(frameGain, gains[index])
            framePeak = max(framePeak, max(abs(left), abs(right)))
            // 这一帧的最后一个采样：记下这一帧，量它末尾的瞬时 / 短时响度，往下一帧走。
            if sample + 1 == outputFrameEnd {
                let current = outputFrame - frameRange.lowerBound
                frames[current].minGain = frameGain
                frames[current].outputPeak = framePeak
                let written = sample + 1 - renderStart
                frames[current].momentaryLUFS = windowLoudness(momentary, total: total, slot: slot, written: written)
                frames[current].shortTermLUFS = windowLoudness(shortTerm, total: total, slot: slot, written: written)
                frameGain = 1
                framePeak = 0
                outputFrame += 1
                outputFrameEnd = min(grid.start(ofFrame: outputFrame + 1), limit)
            }
        }
        emitted += Int64(count)
        weighting = [leftFilter, rightFilter]
        prefixTotal = total
        prefixSlot = slot
        pendingGain = frameGain
        pendingPeak = framePeak
        // 量的范围里的那一截（连着的）喂整体响度：成片同一个门限算法。
        let from = max(firstSample, measured.lowerBound), to = min(firstSample + Int64(count), measured.upperBound)
        if to > from {
            limited.withUnsafeBufferPointer { all in
                loudness.add(UnsafeBufferPointer(rebasing: all[Int(from - firstSample) * 2 ..< Int(to - firstSample) * 2]),
                             frames: Int(to - from))
            }
        }
    }

    /// 最近 `length` 个采样（到刚写出去的这一个为止：一共写出去 `written` 个，前缀和 `total` 在环的 `slot` 格）的 K 加权响度。
    /// 时间线 0 之前没有声音（当静音算进窗里）。
    private func windowLoudness(_ length: Int, total: Double, slot: Int, written: Int64) -> Double? {
        var earlier = 0.0
        if written > Int64(length) {
            let back = slot - length
            earlier = prefix[back >= 0 ? back : back + prefix.count]
        }
        let mean = (total - earlier) / Double(length)
        guard mean > 1e-30 else { return nil }
        return AudioKWeighting.offsetLU + 10 * log10(mean)
    }
}

import Accelerate
import Foundation

// MARK: - 一层声音每一帧多响：整体电平、峰值、四个频段，外加整段响度（流式）
//
// 管什么：一层（AudioStemRender 渲出来的交错立体声 f32，48 kHz）一块一块喂进来，按工程帧率切帧（MixFrameGrid），每一帧给出：
// - **整体**：这一帧的均方（两个声道平均 —— 同 listen 的 level_db 口径：满幅正弦 −3 dB；单声道的素材引擎铺到两边、两边一样，
//   量出来就是它自己在成片里的电平，不会像「先 −3 dB 铺成立体声、量的时候又按单声道算」那样偏 3 dB）和采样峰值；
// - **四个频段**（<300 Hz、300–800、800–3000、>3000 Hz）的均方：以这一帧为中心、两帧长的汉宁窗做 FFT（vDSP），
//   一段的均方 = 落在这一段的频点的能量 ÷ 窗的能量（Parseval：四段加起来 = 窗加权的均方，稳态的信号就是整体电平）。
//   两帧长是因为一帧长的窗会把帧边上的声音压没（帧头的一下敲击在频段里看不见）；两帧长、50% 叠，帧边上的声音在相邻两帧里
//   各算一半。频率分辨率：24 fps 的窗 4000 点（约 83 ms）、补零到 4096；60 fps 的 1600 点、补零到 2048。
//   窗伸出时间线（0 之前、成片结尾之后）的那部分没有声音，不算进窗的能量（按窗在时间线里的那部分归一）。
// - **整段响度**：同一层在量的范围里的 BS.1770 整体响度（ExportLoudnessMeter，和成片同一套 K 加权和门限）。
// 不管什么：渲（AudioStemRender）、整条混音的限幅和瞬时 / 短时响度（MixBusMeter）、写给 AI（AIListenMix）。

/// 一帧的量。
struct MixFrameLevel: Sendable, Equatable {
    /// 这一帧的均方（两个声道平均；只算这一帧在时间线里的那部分）。
    var meanSquare: Double
    /// 这一帧的采样峰值（线性）。
    var peak: Float
    /// 四个频段的均方：<300、300–800、800–3000、>3000 Hz。
    var bands: SIMD4<Double>
}

final class MixBandMeter {
    /// 频段的分界（Hz）：<300 低频、300–800 和 800–3000 是人声的两段、>3000 高频。
    static let bandEdges: [Double] = [300, 800, 3000]

    let grid: MixFrameGrid
    let frameRange: Range<Int>
    /// 时间线的尽头（采样）：之后没有声音（成片正好这么长）。
    let limit: Int64
    /// 量的范围里每一帧（顺序同 `frameRange`）。
    private(set) var levels: [MixFrameLevel] = []
    /// 量的范围里最响的采样（线性）和它在时间线的第几个采样。
    private(set) var peak: Float = 0
    private(set) var peakSample: Int64?
    /// 量的范围里的整段响度（LUFS）；全是静音是 nil。
    var loudnessLUFS: Double? { loudness.integratedLUFS }

    private var loudness = ExportLoudnessMeter(channels: 2)
    private var left: [Float] = []
    private var right: [Float] = []
    /// `left[0]` 是时间线的第几个采样。
    private var bufferStart: Int64?
    private var nextFrame: Int
    private var finished = false
    private let spectrum: Spectrum

    init(grid: MixFrameGrid, frames: Range<Int>, limit: Int64) {
        self.grid = grid
        frameRange = frames
        self.limit = limit
        nextFrame = frames.lowerBound
        // 窗 = 一帧 + 两边各半帧 ≤ 4 × halfFrame。
        spectrum = Spectrum(maxWindow: Int(grid.halfFrame) * 4, sampleRate: grid.sampleRate)
        levels.reserveCapacity(frames.count)
    }

    /// 量的范围（采样）：第一帧的头到最后一帧的尾，收在时间线里。
    var measuredSamples: Range<Int64> {
        let lower = grid.start(ofFrame: frameRange.lowerBound)
        return lower ..< max(lower, min(grid.start(ofFrame: frameRange.upperBound), limit))
    }

    /// 渲出来的一块（交错立体声），从时间线的第 `position` 个采样起。块要一块接一块地喂。
    func add(_ block: UnsafeBufferPointer<Float>, at position: Int64, frames: Int) {
        if bufferStart == nil { bufferStart = position }
        // 拆成左右两路接在后面（vDSP_ctoz：交错的一对当一个复数，实部是左、虚部是右）。
        let base = left.count
        left.append(contentsOf: repeatElement(0, count: frames))
        right.append(contentsOf: repeatElement(0, count: frames))
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var split = DSPSplitComplex(realp: l.baseAddress! + base, imagp: r.baseAddress! + base)
                block.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frames) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frames))
                }
            }
        }
        let measured = measuredSamples
        let from = max(position, measured.lowerBound), to = min(position + Int64(frames), measured.upperBound)
        if to > from {
            let part = UnsafeBufferPointer(rebasing: block[Int(from - position) * 2 ..< Int(to - position) * 2])
            loudness.add(part, frames: Int(to - from))
        }
        drain()
    }

    /// 渲完了：窗伸到后面没渲到的地方是时间线外面（没有声音），量完剩下的帧。
    func finish() {
        finished = true
        drain()
    }

    // MARK: 一帧一帧

    private func window(of frame: Int) -> (start: Int64, end: Int64, frameStart: Int64, frameEnd: Int64) {
        let start = grid.start(ofFrame: frame), end = grid.start(ofFrame: frame + 1)
        let half = (end - start) / 2
        return (start - half, end + half, start, end)
    }

    private func drain() {
        guard let origin = bufferStart else { return }
        while nextFrame < frameRange.upperBound {
            let span = window(of: nextFrame)
            guard finished || origin + Int64(left.count) >= min(span.end, limit) else { break }
            measure(nextFrame, span: span, origin: origin)
            nextFrame += 1
        }
        // 下一帧的窗用不着的样本扔掉。
        let keepFrom = nextFrame < frameRange.upperBound ? window(of: nextFrame).start : origin + Int64(left.count)
        let drop = Int(min(max(0, keepFrom - origin), Int64(left.count)))
        if drop > 0 {
            left.removeFirst(drop)
            right.removeFirst(drop)
            bufferStart = origin + Int64(drop)
        }
    }

    private func measure(_ frame: Int, span: (start: Int64, end: Int64, frameStart: Int64, frameEnd: Int64), origin: Int64) {
        let available = origin + Int64(left.count)
        // 整体：这一帧在时间线里的那部分。
        let from = max(span.frameStart, origin), to = min(span.frameEnd, limit, available)
        var level = MixFrameLevel(meanSquare: 0, peak: 0, bands: .zero)
        if to > from {
            let offset = Int(from - origin), count = Int(to - from)
            var sumL: Float = 0, sumR: Float = 0, maxL: Float = 0, maxR: Float = 0
            var indexL: vDSP_Length = 0, indexR: vDSP_Length = 0
            left.withUnsafeBufferPointer { l in
                vDSP_svesq(l.baseAddress! + offset, 1, &sumL, vDSP_Length(count))
                vDSP_maxmgvi(l.baseAddress! + offset, 1, &maxL, &indexL, vDSP_Length(count))
            }
            right.withUnsafeBufferPointer { r in
                vDSP_svesq(r.baseAddress! + offset, 1, &sumR, vDSP_Length(count))
                vDSP_maxmgvi(r.baseAddress! + offset, 1, &maxR, &indexR, vDSP_Length(count))
            }
            level.meanSquare = (Double(sumL) + Double(sumR)) / Double(2 * count)
            level.peak = max(maxL, maxR)
            if level.peak > peak || peakSample == nil, level.peak > 0 {
                peak = level.peak
                peakSample = from + Int64(maxL >= maxR ? indexL : indexR)
            }
        }
        // 频段：两帧长的窗，时间线外面（和还没渲到的地方）当静音、不算窗的能量。
        let valid = max(span.start, 0, origin) ..< min(span.end, limit, available)
        level.bands = spectrum.bands(
            left: left, right: right, origin: origin, window: span.start ..< span.end, valid: valid
        )
        levels.append(level)
    }
}

/// 两帧长的汉宁窗 + 实数 FFT（vDSP），算四个频段的均方。一个 MixBandMeter 一份，缓冲预分配。
private final class Spectrum {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let sampleRate: Int
    /// 频点 1 ..< size/2 按频段分好（直流算低频、奈奎斯特算高频）。
    private let bins: [Range<Int>]
    private var input: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    /// 当前的汉宁窗（长度、系数、整个窗的能量 Σw²）。
    private var hann: (length: Int, values: [Float], energy: Double) = (0, [], 0)

    init(maxWindow: Int, sampleRate: Int) {
        var log2n: vDSP_Length = 1
        while (1 << log2n) < maxWindow { log2n += 1 }
        self.log2n = log2n
        let size = 1 << Int(log2n)
        self.size = size
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let half = size / 2
        // 频点 k 的频率 = k × 采样率 ÷ size；某一段 = 频率落在 [下界, 上界) 的那些频点。
        var edges = MixBandMeter.bandEdges.map { min(half, max(1, Int((($0 * Double(size)) / Double(sampleRate)).rounded(.up)))) }
        edges = [1] + edges + [half]
        bins = (0..<4).map { edges[$0] ..< max(edges[$0], edges[$0 + 1]) }
        input = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func bands(left: [Float], right: [Float], origin: Int64, window: Range<Int64>, valid: Range<Int64>) -> SIMD4<Double> {
        let length = Int(window.count)
        guard valid.count > 0, length <= size else { return .zero }
        if hann.length != length {
            let values = (0..<length).map { 0.5 - 0.5 * cos(2 * Float.pi * (Float($0) + 0.5) / Float(length)) }
            hann = (length, values, values.reduce(0.0) { $0 + Double($1) * Double($1) })
        }
        var energy = hann.energy
        if valid.count != length {
            energy = 0
            for index in Int(valid.lowerBound - window.lowerBound) ..< Int(valid.upperBound - window.lowerBound) {
                energy += Double(hann.values[index]) * Double(hann.values[index])
            }
        }
        guard energy > 0 else { return .zero }
        let total = channelBands(left, origin: origin, window: window, valid: valid)
            + channelBands(right, origin: origin, window: window, valid: valid)
        return total / (2 * energy)
    }

    /// 一个声道：窗内的能量按频段分（Parseval，没除窗的能量）。
    private func channelBands(_ samples: [Float], origin: Int64, window: Range<Int64>, valid: Range<Int64>) -> SIMD4<Double> {
        input.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }
        let first = Int(valid.lowerBound - window.lowerBound)
        let count = Int(valid.count)
        samples.withUnsafeBufferPointer { source in
            hann.values.withUnsafeBufferPointer { weights in
                input.withUnsafeMutableBufferPointer { out in
                    vDSP_vmul(source.baseAddress! + Int(valid.lowerBound - origin), 1, weights.baseAddress! + first, 1,
                              out.baseAddress! + first, 1, vDSP_Length(count))
                }
            }
        }
        var dc: Float = 0, nyquist: Float = 0
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { data in
                    data.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP 的正向实数 FFT 是数学定义的 2 倍；[0] 里装的是直流（实部）和奈奎斯特（虚部）。
                dc = re[0] * re[0] / 4
                nyquist = im[0] * im[0] / 4
                re[0] = 0
                im[0] = 0
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvmags(&split, 1, mags.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
        // 1 ..< size/2 的频点在双边谱里各出现两次：|X|² × 2 = (2X)² ÷ 2。
        var result = SIMD4<Double>.zero
        magnitudes.withUnsafeBufferPointer { mags in
            for band in 0..<4 where !bins[band].isEmpty {
                var sum: Float = 0
                vDSP_sve(mags.baseAddress! + bins[band].lowerBound, 1, &sum, vDSP_Length(bins[band].count))
                result[band] = Double(sum) / 2
            }
        }
        result[0] += Double(dc)
        result[3] += Double(nyquist)
        return result / Double(size)
    }
}

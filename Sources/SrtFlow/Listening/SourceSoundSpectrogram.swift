import Foundation

/// 原声特征里靠频谱的那几样：重心、平坦度、低频占比、音级、拍子（`SourceSoundFeatures` 用；docs/architecture/listening-engine.md）。
///
/// 管什么：16 kHz 一窗的功率谱（1488 点汉宁窗、跳 744 点，numpy 的 `hanning` 和 `rfftfreq` 写法），和从它算出来的那几样。
/// 每一样的口径、边界（≥ / ≤ / <）都照研究时的 numpy 版逐条对过，改之前先看架构文档「和 Python 版对」。
/// 不管什么：不靠频谱的音高、电平稳不稳、2–8 Hz 起伏（在 `SourceSoundFeatures` 里）。
struct SourceSoundSpectrogram {
    /// [帧][频点] 的 |X|²。
    let power: [[Double]]
    let frequencies: [Double]
    /// 一跳多少秒（744 / 16000 = 0.0465）。
    let frameStep: Double

    init(_ x: [Double]) {
        let n = SourceSoundFeatures.frameLength
        let window = ListeningMath.hanning(n)
        let dft = ListeningDFT(length: n)
        var frame = [Double](repeating: 0, count: n)
        power = stride(from: 0, to: x.count - n, by: SourceSoundFeatures.hop).map { start in
            for i in 0..<n { frame[i] = window[i] * x[start + i] }
            let spectrum = dft.realForward(frame)
            return zip(spectrum.re, spectrum.im).map { $0 * $0 + $1 * $1 }
        }
        frequencies = ListeningMath.rfftFrequencies(count: n, spacing: 1 / SourceSoundFeatures.sampleRate)
        frameStep = Double(SourceSoundFeatures.hop) / SourceSoundFeatures.sampleRate
    }

    struct Shape {
        let centroid: Double
        let flatness: Double
        let lowShare: Double
        /// 哪几帧算「响」：50–8000 Hz 的总能量高过最响一帧的万分之一。
        let loud: [Bool]
    }

    /// 50–8000 Hz 的频点（每个加 1e-12 防 log 0）上算重心、平坦度，响的帧取中位；低频占比按全部帧、不加 1e-12。
    func shape() -> Shape {
        let band = frequencies.indices.filter { frequencies[$0] >= 50 && frequencies[$0] <= 8000 }
        let totals = power.map { frame in band.reduce(0) { $0 + frame[$1] + 1e-12 } }
        let threshold = (totals.max() ?? 0) * 1e-4
        let loud = totals.map { $0 > threshold }
        var centroids: [Double] = []
        var flatnesses: [Double] = []
        for (index, frame) in power.enumerated() where loud[index] {
            var weighted = 0.0
            var logSum = 0.0
            for k in band {
                let value = frame[k] + 1e-12
                weighted += value * frequencies[k]
                logSum += log(value)
            }
            centroids.append(weighted / totals[index])
            flatnesses.append(exp(logSum / Double(band.count)) / (totals[index] / Double(band.count)))
        }
        var low = 0.0
        var all = 0.0
        for frame in power {
            for k in frequencies.indices where frequencies[k] >= 20 {
                if frequencies[k] < 300 { low += frame[k] }
                if frequencies[k] <= 8000 { all += frame[k] }
            }
        }
        return Shape(centroid: ListeningMath.median(centroids) ?? .nan, flatness: ListeningMath.median(flatnesses) ?? .nan,
                     lowShare: low / (all + 1e-12), loud: loud)
    }

    /// 55–2000 Hz 的频点归到最近的半音（12·log2(f/440) 一半取偶地取整，再对 12 取模）。
    /// 集中度：每帧归一以后最强 3 个加起来，响的帧取平均。稳不稳：每 10 帧（int(0.5 / 0.0465)）一块、不归一地加起来，
    /// 相邻两块的余弦相似度取中位。
    func chroma(loud: [Bool]) -> (top3: Double, stability: Double?) {
        let selected = frequencies.indices.filter { frequencies[$0] >= 55 && frequencies[$0] <= 2000 }
        let pitchClass = selected.map { k -> Int in
            let semitone = Int((12 * log2(frequencies[k] / 440.0)).rounded(.toNearestOrEven))
            return ((semitone % 12) + 12) % 12
        }
        let classes = power.map { frame -> [Double] in
            var c = [Double](repeating: 0, count: 12)
            for (k, pc) in zip(selected, pitchClass) { c[pc] += frame[k] }
            return c
        }
        var top3: [Double] = []
        for (index, c) in classes.enumerated() where loud[index] {
            let total = c.reduce(0, +) + 1e-12
            let sorted = c.map { $0 / total }.sorted()
            top3.append(sorted[9] + sorted[10] + sorted[11])
        }
        let block = max(1, Int(0.5 / frameStep))
        let blocks = stride(from: 0, through: classes.count - block, by: block).map { start in
            (start..<(start + block)).reduce(into: [Double](repeating: 0, count: 12)) { sum, frame in
                for pc in 0..<12 { sum[pc] += classes[frame][pc] }
            }
        }
        let similarities = zip(blocks, blocks.dropFirst()).map { a, b -> Double in
            let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
            let norms = a.reduce(0) { $0 + $1 * $1 }.squareRoot() * b.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return dot / (norms + 1e-12)
        }
        return (ListeningMath.mean(top3), ListeningMath.median(similarities))
    }

    /// 六个频带（50–200–500–1000–2000–4000–8000 Hz，左闭右开）各自的正向频谱通量（对数功率逐帧涨了多少），
    /// 每带除以自己的平均再相加；去均值以后的自相关除以零延迟，取 0.3–1.5 秒那几个延迟（int(秒 / 0.0465)）里最高的。
    func pulseClarity() -> Double? {
        let edges: [Double] = [50, 200, 500, 1000, 2000, 4000, 8000]
        guard power.count >= 2 else { return nil }
        let logPower = power.map { $0.map { log($0 + 1e-10) } }
        var flux = [Double](repeating: 0, count: power.count - 1)
        for (low, high) in zip(edges, edges.dropFirst()) {
            let bins = frequencies.indices.filter { frequencies[$0] >= low && frequencies[$0] < high }
            let rises = (0..<(power.count - 1)).map { t in
                bins.reduce(0) { $0 + max(0, logPower[t + 1][$1] - logPower[t][$1]) }
            }
            let mean = rises.reduce(0, +) / Double(rises.count)
            for t in flux.indices { flux[t] += rises[t] / (mean + 1e-12) }
        }
        let fluxMean = flux.reduce(0, +) / Double(flux.count)
        let onset = flux.map { $0 - fluxMean }
        let shortest = Int(0.3 / frameStep)
        let longest = Int(1.5 / frameStep)
        guard longest < onset.count else { return nil }
        func lagSum(_ lag: Int) -> Double {
            var sum = 0.0
            for t in 0..<(onset.count - lag) { sum += onset[t + lag] * onset[t] }
            return sum
        }
        let zeroLag = lagSum(0) + 1e-12
        return (shortest..<longest).map { lagSum($0) / zeroLag }.max()
    }
}

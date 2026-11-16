import Accelerate
import Foundation

/// 没来路的原声（素材自带的声音）的几样便宜特征（docs/architecture/listening-engine.md 第 3 步）。
///
/// 管什么：16 kHz 单声道一窗（研究用 3 秒）→ 九个数，照研究时的 numpy 版（同一份输入上逐位对得上，差在 1e-9 以内）：
/// 频谱重心、平坦度、300 Hz 以下占比、音级集中度（最强 3 个音级占比）、音级稳不稳（相邻 0.5 秒）、音高强度、拍子清不清楚、
/// 电平稳不稳（每 0.1 秒电平的标准差）、2–8 Hz 起伏占比（说话的音节节奏在 4 Hz 上下）。
/// 不管什么：把它们说成话（`SourceSoundTrait`）；**不判「是不是音乐」** —— 研究里一个纯低音效果按这几样比音乐还像音乐，
/// 够描述、不够分类；苹果 SoundAnalysis 每个标签的分数、SpeechTranscriber 有没有字要系统接口和真文件，留给接线的任务。
struct SourceSoundFeatures: Equatable {
    static let sampleRate = 16_000.0
    /// 93 ms 一帧、46.5 ms 一跳（1488 不是 vDSP 认的长度，走 `ListeningDFT` 的 Bluestein）。
    static let frameLength = 1488
    static let hop = 744

    /// 频谱重心（Hz）：闷还是亮。响的帧取中位。
    let centroidHz: Double
    /// 频谱平坦度：1 = 白噪声，近 0 = 能量挤在少数频率上。响的帧取中位。
    let flatness: Double
    /// 20–300 Hz 的能量占 20–8000 Hz 的比例。
    let lowShare: Double
    /// 12 个音级里最强 3 个占多少（完全平均 = 0.25，一个和弦高得多）。响的帧取平均。
    let chromaTop3: Double
    /// 相邻 0.5 秒的音级分布有多像（余弦相似度，中位）：长音、持续的和声高。不够两块是 nil。
    let chromaStability: Double?
    /// 音高强度：每 40 ms 起一段 80 ms，归一化自相关在 60–1000 Hz 的周期上的最高峰，取中位。没有够响的段是 nil。
    let pitchStrength: Double?
    /// 拍子清不清楚：分频带的频谱通量，自相关在 0.3–1.5 秒上的最高峰。窗太短是 nil。
    let pulseClarity: Double?
    /// 每 0.1 秒电平的标准差（dB，只算比最响低不到 40 dB 的格子）：小 = 稳。
    let levelSpreadDB: Double
    /// 电平包络的调制谱里 2–8 Hz 占 0.5–32 Hz 的比例。
    let syllabicShare: Double

    /// x：16 kHz、单声道的一窗。不到 1 秒回 nil（研究只在 3 秒的窗上量过）。
    static func measure(_ x: [Double]) -> SourceSoundFeatures? {
        guard x.count >= Int(sampleRate) else { return nil }
        let spectrum = SourceSoundSpectrogram(x)
        let shape = spectrum.shape()
        let chroma = spectrum.chroma(loud: shape.loud)
        return SourceSoundFeatures(
            centroidHz: shape.centroid, flatness: shape.flatness, lowShare: shape.lowShare,
            chromaTop3: chroma.top3, chromaStability: chroma.stability,
            pitchStrength: pitchStrength(x), pulseClarity: spectrum.pulseClarity(),
            levelSpreadDB: levelSpread(x), syllabicShare: syllabicShare(x))
    }

    /// 每 40 ms 起一段 80 ms：去均值、太轻（RMS < 1e-4）的不要；自相关除以零延迟，取 16–265 个采样（1000–60 Hz）里最高的。
    private static func pitchStrength(_ x: [Double]) -> Double? {
        let step = Int(0.04 * sampleRate)
        let length = 2 * step
        let shortest = Int(sampleRate) / 1000
        let longest = Int(sampleRate) / 60
        var peaks: [Double] = []
        for start in stride(from: 0, to: x.count - length, by: step) {
            let slice = x[start..<(start + length)]
            let mean = slice.reduce(0, +) / Double(length)
            let segment = slice.map { $0 - mean }
            let zeroLag = segment.reduce(0) { $0 + $1 * $1 }
            guard (zeroLag / Double(length)).squareRoot() >= 1e-4 else { continue }
            var best = -Double.infinity
            segment.withUnsafeBufferPointer { p in
                for lag in shortest..<longest {
                    var sum = 0.0
                    vDSP_dotprD(p.baseAddress! + lag, 1, p.baseAddress!, 1, &sum, vDSP_Length(length - lag))
                    best = max(best, sum)
                }
            }
            var r0 = 0.0
            segment.withUnsafeBufferPointer { vDSP_dotprD($0.baseAddress!, 1, $0.baseAddress!, 1, &r0, vDSP_Length(length)) }
            peaks.append(best / (r0 + 1e-12))
        }
        return ListeningMath.median(peaks)
    }

    /// 每 0.1 秒一格的电平（dB），比最响的一格低不到 40 dB 的那些格子的标准差。
    private static func levelSpread(_ x: [Double]) -> Double {
        let cell = Int(0.1 * sampleRate)
        let levels = blockMeanSquares(x, block: cell).map { 10 * log10($0 + 1e-10) }
        let loudest = levels.max() ?? 0
        return ListeningMath.standardDeviation(levels.filter { $0 > loudest - 40 })
    }

    /// 每 10 ms 的 RMS 包络去均值、加汉宁窗做 DFT，2–8 Hz 的能量占 0.5–32 Hz 的比例。
    private static func syllabicShare(_ x: [Double]) -> Double {
        let cell = Int(0.01 * sampleRate)
        var envelope = blockMeanSquares(x, block: cell).map { $0.squareRoot() }
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        let window = ListeningMath.hanning(envelope.count)
        for i in envelope.indices { envelope[i] = (envelope[i] - mean) * window[i] }
        let spectrum = ListeningDFT(length: envelope.count).realForward(envelope)
        let frequencies = ListeningMath.rfftFrequencies(count: envelope.count, spacing: 0.01)
        var syllabic = 0.0
        var all = 0.0
        for k in frequencies.indices {
            let power = spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k]
            if frequencies[k] >= 2, frequencies[k] <= 8 { syllabic += power }
            if frequencies[k] >= 0.5, frequencies[k] <= 32 { all += power }
        }
        return syllabic / (all + 1e-12)
    }

    /// 每 `block` 个采样一格的均方（多出来不满一格的尾巴不要）。
    static func blockMeanSquares(_ x: [Double], block: Int) -> [Double] {
        (0..<(x.count / block)).map { b in
            var sum = 0.0
            for i in (b * block)..<((b + 1) * block) { sum += x[i] * x[i] }
            return sum / Double(block)
        }
    }
}

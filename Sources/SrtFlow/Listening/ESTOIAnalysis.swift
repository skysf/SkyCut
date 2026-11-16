import Foundation

/// ESTOI 的前半截：10 kHz 上分帧、去掉干净人声不说话的帧、15 个三分之一倍频程带的包络（docs/architecture/listening-engine.md）。
///
/// 参数照 STOI / ESTOI 的论文（Taal 等 2011、Jensen & Taal 2016）和研究时自己写、验过的 numpy 版：
/// 10 kHz；256 点汉宁窗（25.6 ms）、跳 128 点、512 点 FFT；15 个带，中心 150 Hz 起每带 1/3 倍频程（到约 3.8 kHz）；
/// 去静音：比干净人声最响的一帧低 40 dB 以上的帧，干净和混音两边都去掉，剩下的帧叠加回一条连续的信号再分析。
/// 最低一带的下沿是第 7 个频点（136.7 Hz）：**ESTOI 看不见约 134 Hz 以下**，那一截另报（`MaskerAttribution`）。
///
/// 管什么：上面这几样，全是确定的纯计算。不管什么：段内归一和打分（`ESTOI`）；重采样（`ListeningResample`）。
enum ESTOIAnalysis {
    static let sampleRate = 10_000.0
    static let frameLength = 256
    static let hop = 128
    static let fftLength = 512
    static let bandCount = 15
    static let lowestCenterHz = 150.0
    static let dynamicRangeDB = 40.0
    /// numpy 的 `np.finfo(float).eps`。只防除以零。
    static let eps = Double.ulpOfOne

    /// numpy 的 `hanning(258)[1:-1]`：两头的 0 去掉，256 点。
    static let window: [Double] = Array(ListeningMath.hanning(frameLength + 2).dropFirst().dropLast())

    /// 每个带占哪几个频点（闭区间的下标）。和 numpy 版一样：带的上下沿各取离它最近的频点，区间左闭右开。
    static let bandBins: [ClosedRange<Int>] = {
        let binCount = fftLength / 2 + 1
        let step = sampleRate / Double(fftLength)   // 19.53125 Hz，二进制里是精确的
        let frequencies = (0..<binCount).map { Double($0) * step }
        func nearest(_ target: Double) -> Int {
            var best = 0
            for k in 1..<binCount where (frequencies[k] - target) * (frequencies[k] - target)
                < (frequencies[best] - target) * (frequencies[best] - target) {
                best = k
            }
            return best
        }
        return (0..<bandCount).map { band in
            let k = Double(band)
            let low = nearest(lowestCenterHz * pow(2, (2 * k - 1) / 6))
            let high = nearest(lowestCenterHz * pow(2, (2 * k + 1) / 6))
            return low...(high - 1)
        }
    }()

    /// 第 f 帧从第几个采样起：0、128、256……，起点要 < n − 256（不含），和 pystoi 一样最后一帧可能不要。
    static func frameStarts(sampleCount n: Int) -> [Int] {
        guard n > frameLength else { return [] }
        return Array(stride(from: 0, to: n - frameLength, by: hop))
    }

    /// 干净人声里哪几帧算「在说话」：20·log10(‖加窗的一帧‖ + eps) 比最响的一帧低不到 40 dB。
    static func speechFrames(clean x: [Double]) -> [Int] {
        let starts = frameStarts(sampleCount: x.count)
        guard !starts.isEmpty else { return [] }
        let energies = starts.map { start -> Double in
            var sum = 0.0
            for i in 0..<frameLength {
                let v = window[i] * x[start + i]
                sum += v * v
            }
            return 20 * log10(sum.squareRoot() + eps)
        }
        let loudest = energies.max() ?? 0
        return starts.indices.filter { loudest - dynamicRangeDB - energies[$0] < 0 }.map { starts[$0] }
    }

    /// 只留这几帧：加窗后按 128 点的间隔叠回一条连续的信号（overlap-add，不再除窗），pystoi 的 `remove_silent_frames`。
    static func keep(_ x: [Double], frames starts: [Int]) -> [Double] {
        guard !starts.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: (starts.count - 1) * hop + frameLength)
        for (slot, start) in starts.enumerated() {
            let offset = slot * hop
            for i in 0..<frameLength { out[offset + i] += window[i] * x[start + i] }
        }
        return out
    }

    /// 15 × 帧数的带包络：每帧再加一次窗、补零做 512 点 FFT，每个带里 |X|² 加起来开方。按 [帧][带] 存。
    static func bandEnvelopes(_ x: [Double]) -> [[Double]] {
        let starts = frameStarts(sampleCount: x.count)
        guard !starts.isEmpty else { return [] }
        let dft = ListeningDFT(length: fftLength)
        var padded = [Double](repeating: 0, count: fftLength)
        return starts.map { start in
            for i in 0..<frameLength { padded[i] = window[i] * x[start + i] }
            let spectrum = dft.realForward(padded)
            return bandBins.map { bins in
                var power = 0.0
                for k in bins { power += spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k] }
                return power.squareRoot()
            }
        }
    }
}

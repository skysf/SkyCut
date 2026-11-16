import Foundation

/// 「听声音的引擎」里几样小的数学，写法照 numpy（docs/architecture/listening-engine.md「和 Python 版对」）。
///
/// 管什么：汉宁窗、频点的频率、中位数、标准差 —— 研究时 numpy 版用到、和它逐位对得上才有意义的那几样。
/// 写法照 numpy 的源码，不照教科书。最要紧的是频点的频率：同一个式子换个写法最后一位就不一样，落在频带边界上的频点就换了带。
/// 实测：1488 点的窗（16 kHz），numpy 的 k × (1 / (n·d)) 算出第 93、186、372 个频点是 999.9999999999999、1999.9999999999998、
/// 3999.9999999999995，归到下面那一带；按 k × 16000 / 1488 算正好是 1000、2000、4000，就进了上面那一带，「拍子清不清楚」
/// 跟着变（自检里六种声音的拍子都和 Python 版对不上了）。汉宁窗换个写法只差最后一位、不影响结果，照 numpy 写是少一处要解释的差别。
/// 不管什么：DFT（`ListeningDFT`）、重采样和电平（`ListeningResample` / `ListeningLevel`）。
enum ListeningMath {
    /// numpy 的 `hanning(m)`：n 取 1−m、3−m……m−1，0.5 + 0.5·cos(π·n/(m−1))（两头是 0）。
    static func hanning(_ m: Int) -> [Double] {
        guard m > 1 else { return m == 1 ? [1] : [] }
        return stride(from: 1 - m, through: m - 1, by: 2).map { 0.5 + 0.5 * cos(Double.pi * Double($0) / Double(m - 1)) }
    }

    /// numpy 的 `rfftfreq(n, d)`：k × (1 / (n·d))，k = 0…n/2。
    static func rfftFrequencies(count n: Int, spacing d: Double) -> [Double] {
        let step = 1.0 / (Double(n) * d)
        return (0...(n / 2)).map { Double($0) * step }
    }

    /// numpy 的 `median`：排好序取中间；偶数个取中间两个的平均。空的回 nil（numpy 是 NaN）。
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// numpy 的 `std`（总体标准差，ddof = 0）。
    static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }
}

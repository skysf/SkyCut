import Foundation

// MARK: - Kokoro 的语速：要多少给多少（纯值）
//
// 管什么：add_voiceover 的 speed（1 = 正常，0.85 = 慢一成半）换成给 Kokoro 模型的 speed。读出来的长短对模型的 speed 反应比 1 ÷ speed
// 弱、每句还不一样：模型给的时长按一格（600 个采样、25 毫秒）取整，段和段之间按标点停的那一截（KokoroVoicePieces）也不跟着变 ——
// 0.95 → 0.85 只慢了 4.7%，换一句又是 13%（2026-10-14 实测 zm_yunxi；docs/bugfixes/2026-10-14-kokoro-speed-barely-changes.md）。
// 所以按时长对准：先按 1 倍读一遍，目标 = 1 倍的时长 ÷ speed；读出来差得多就用读过的几次拟合「时长 ≈ a + b ÷ 给模型的 speed」
// 再给一次，差 3% 以内就停，最多读五遍（1 倍那一遍 + 四次）。
// 不管什么：怎么读、怎么拼（KokoroVoiceSpeech / KokoroPieceReader / KokoroVoiceAssembly）。

enum KokoroSpeedCalibration {
    /// 读出来的时长和目标差在这个比例以内就算对上了。
    static let tolerance = 0.03
    /// 1 倍那一遍之外最多再读几次。
    static let attempts = 4
    /// 给模型的 speed 夹在这个范围里（太快太慢都会读坏）。
    static let modelRange: ClosedRange<Double> = 0.5...2.2

    /// 读出来的时长对上目标了吗。
    static func isClose(_ duration: Double, to target: Double) -> Bool {
        target > 0 && abs(duration - target) <= target * tolerance
    }

    /// 下一次给模型的 speed。`tried`：读过的（给模型的 speed，读出来多长），按读的先后；至少有 1 倍那一遍。
    /// 时长按「a + b ÷ speed」走（停顿是 a、说话的部分是 b ÷ speed），可它是一格一格跳的，外推会冲过头：
    /// - 已经有比目标长的、也有比目标短的：在离目标最近的那两次之间按 1 ÷ speed 线性插值（夹在两次中间，不会再冲出去）；
    /// - 都在一边：用最后两次拟合 a、b 解出目标；拟合不出来（两次一样长、斜率不对）就按比例推。
    static func next(target: Double, tried: [(speed: Double, duration: Double)]) -> Double {
        guard let last = tried.last, target > 0 else { return 1 }
        let longer = tried.filter { $0.duration > target }.min { $0.duration < $1.duration }
        let shorter = tried.filter { $0.duration < target }.max { $0.duration < $1.duration }
        var guess = last.speed * last.duration / target
        if let longer, let shorter {
            let fraction = (longer.duration - target) / (longer.duration - shorter.duration)
            let inverse = 1 / longer.speed + fraction * (1 / shorter.speed - 1 / longer.speed)
            guess = 1 / inverse
        } else if tried.count >= 2 {
            let previous = tried[tried.count - 2]
            let inverseGap = 1 / previous.speed - 1 / last.speed
            if abs(inverseGap) > 1e-9 {
                let slope = (previous.duration - last.duration) / inverseGap
                let offset = last.duration - slope / last.speed
                if slope > 0, target > offset { guess = slope / (target - offset) }
            }
        }
        return min(max(guess, modelRange.lowerBound), modelRange.upperBound)
    }
}

import Foundation

// MARK: - 同一个种子永远出同一串的随机数（SplitMix64）
//
// 管什么：一个很小的确定性随机数。跨机器、跨版本同一个种子同一串 —— 系统的随机数做不到这一点。
// 用它的：合成音效（SFXRandom：同参数渲出来逐采样一样）、导出水印的位置表（WatermarkPlacement：一次导出里能复现）。
// 不管什么：种子从哪来、拿随机数做什么。

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, n)
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

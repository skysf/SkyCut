import Foundation

// MARK: - 播放头的外推（纯值）
//
// Split out of VideoPreviewView.swift on 2026-11-19 (PlayerClock.estimatedTime uses it).

/// `PlayerClock.estimatedTime` 的算术：最近一跳 `tick` 是在 host 时间 `tickHost` 落地的，现在是 `now`。
/// 播放中就把过去的这段时间补上，但最多补 `maxLead`（时钟的回调间隔）—— 回调要是晚到了，外推不许
/// 一直往前跑；停着就是 `tick` 本身。`now` 比 `tickHost` 还早（时钟倒退）按没过时间算。
enum PlaybackTimeEstimate {
    static func estimate(tick: TimeInterval, tickHost: TimeInterval, now: TimeInterval,
                         isPlaying: Bool, maxLead: TimeInterval) -> TimeInterval {
        guard isPlaying, tickHost > 0 else { return tick }
        let elapsed = min(max(0, now - tickHost), max(0, maxLead))
        return tick + elapsed
    }
}

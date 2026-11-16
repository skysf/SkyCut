import Foundation

// MARK: - 按工程帧率切帧：时间线的第几帧 ↔ 48 kHz 的第几个采样（纯值）
//
// 管什么：按层量混音（MixMeasurement）每个数都落在一帧上：帧率只从工程来（`TimelineState.frameRate`，
// docs/architecture/project-frame-rate.md，不许写死），这里只做换算。第 k 帧 = 采样 [start(k), start(k + 1))，
// 边界按 k × 采样率 ÷ 帧率四舍五入（24 / 30 / 60 fps 在 48 kHz 下正好整除：2000 / 1600 / 800 个采样一帧）。
// 不管什么：量（MixBandMeter、MixBusMeter）。

struct MixFrameGrid: Sendable, Equatable {
    let fps: Int
    let sampleRate: Int

    init(fps: Int, sampleRate: Int = AudioKWeighting.sampleRate) {
        precondition(fps > 0 && sampleRate > 0)
        self.fps = fps
        self.sampleRate = sampleRate
    }

    /// 第 `frame` 帧从第几个采样起。
    func start(ofFrame frame: Int) -> Int64 {
        Int64((Double(frame) * Double(sampleRate) / Double(fps)).rounded())
    }

    /// 第 `frame` 帧从时间线第几秒起。
    func seconds(ofFrame frame: Int) -> Double { Double(frame) / Double(fps) }

    /// 这一秒落在哪一帧里（帧头算这一帧）。
    func frame(containing seconds: Double) -> Int {
        Int((seconds * Double(fps) + 1e-6).rounded(.down))
    }

    /// 量到这一秒为止要量到哪一帧（不含）：盖住这一秒之前的最后一帧之后那一帧。
    func frame(endingAt seconds: Double) -> Int {
        Int((seconds * Double(fps) - 1e-6).rounded(.up))
    }

    /// 第 `sample` 个采样落在哪一帧（和 `start(ofFrame:)` 的边界一致）。
    func frame(ofSample sample: Int64) -> Int {
        var frame = Int((Double(sample) * Double(fps) / Double(sampleRate)).rounded(.down))
        while start(ofFrame: frame + 1) <= sample { frame += 1 }
        while frame > 0, start(ofFrame: frame) > sample { frame -= 1 }
        return frame
    }

    /// 最长的半帧（采样数）：频段的窗往两边各借半帧，渲的时候要多渲这么多。
    var halfFrame: Int64 { (Int64(sampleRate) + Int64(fps) - 1) / Int64(fps) / 2 + 1 }
}

import AVFoundation
import Foundation
import Synchronization

// MARK: - 引擎的时钟：渲染线程每拍写，别处读
//
// 管什么：最近一拍的采样时间、它出声卡的 host 时间、这一拍多少帧，欠载的帧数，以及「图这一次起来之后报过时间没有」。
// **采样时间只从渲染块的时间戳来**（节点的 48 kHz 域）—— `outputNode.lastRenderTime` 是声卡自己的采样率（这台机器
// 44.1 kHz），拿它算位置播放头会以 0.92 倍速走（2026-10-01 冒烟：欠载 51k 帧、视频对表 60 次）。
// `Atomic` 不能拷贝、不能被闭包按值捕获，所以收在一个引用里；渲染块里只做原子写。
// 不管什么：这些数怎么换成时间线的位置（PlaybackAnchor、TimelineAudioEngine）。

final class AudioRenderClock: @unchecked Sendable {
    /// 最近一拍的采样时间（这一拍第一帧的）。
    let sampleTime = Atomic<Int64>(0)
    /// 最近一拍对应的 host 时间（这一拍第一帧出声卡的时刻）。
    let hostTime = Atomic<UInt64>(0)
    /// 最近一拍多少帧：开播 / seek 时锚点要钉在**下一拍**上，差这么多。
    let quantum = Atomic<Int>(0)
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。
    let underruns = Atomic<Int>(0)
    /// 图这一次起来之后渲染块报过时间没有。没报过（刚起、还在起、停着）就不知道下一拍的采样时间：发待钉的锚点。
    let ticked = Atomic<Bool>(false)

    /// 渲染块每拍调：记下这一拍的时间戳。
    func tick(_ timestamp: UnsafePointer<AudioTimeStamp>, frames: Int) {
        let stamp = timestamp.pointee
        sampleTime.store(Int64(stamp.mSampleTime), ordering: .relaxed)
        hostTime.store(stamp.mHostTime, ordering: .relaxed)
        quantum.store(frames, ordering: .relaxed)
        ticked.store(true, ordering: .relaxed)
    }

    /// 图停了 / 要重起：旧的采样时间、host 时间不带过去。
    func reset() {
        ticked.store(false, ordering: .relaxed)
        sampleTime.store(0, ordering: .relaxed)
        hostTime.store(0, ordering: .relaxed)
        quantum.store(0, ordering: .relaxed)
    }
}

import Darwin
import Foundation
import Synchronization

// MARK: - 播放头的锚点：引擎的哪一拍对着时间线的哪一帧
//
// 管什么：「引擎采样时间 S 那一刻，时间线在第 P 帧」这一对数，和它的两种来法 ——
//   1. 图在跑、时钟有数：发布方直接写明钉在哪一拍（`init(position:sampleTime:playing:)`，开播 / seek 钉在下一拍）；
//   2. 图刚起、还没起、或者故意停着（空闲，docs/architecture/audio-engine.md 第二节第 11 条）：发布方不知道下一拍的
//      采样时间是多少（停过再起，采样时间不保证从 0 起：2026-11-11 在真声卡上量到它接着停之前的数往下走），就发一个
//      **待钉**的锚点（`pending`）：第一个看到它的渲染块按自己这一拍的时间戳钉上，之后所有轨都用钉好的那一拍。
// 待钉的锚点可以带着发布那一刻的 host 时间（图没在跑的时候发的：没有声音所以故意停着的时间线在播、或者播着的时候图
// 正在起回来）：钉上之前播放头按 host 时间走；钉的时候把这段已经过去的时间算进去，声音从此刻该在的位置接上，位置不跳。
// 不带 host 时间（传 0：图在跑、只是刚起还没报过时间，和离线渲染）：钉在第一拍、位置不动。
// 不管什么：谁发布、什么时候发布（TimelineAudioEngine）；渲染（AudioTrackRenderer）。
//
// 实时安全：`position(sampleTime:hostTime:)` 在渲染块里调 —— 只有原子读写和算术，不分配、不加锁。

final class PlaybackAnchor: @unchecked Sendable {
    /// 还没钉上的记号（真的采样时间到不了这个数）。
    private static let unlatched = Int64.min
    /// 一个 host 时间单位（mach tick）是引擎的几帧。
    private static let framesPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000 * AudioSegmentReader.engineRate
    }()

    /// 锚点那一刻时间线在第几帧；`playing` 为 false 时位置钉住。
    let position: Int64
    let playing: Bool
    /// 发布那一刻的 host 时间（0 = 不按 host 时间走：离线渲染、写明了钉在哪一拍的锚点）。
    let hostTime: UInt64
    /// 钉在引擎采样时间的哪一拍上（`unlatched` = 待钉）。
    private let base: Atomic<Int64>

    /// 写明钉在哪一拍（图在跑、时钟有数时）。
    init(position: Int64, sampleTime: Int64, playing: Bool) {
        self.position = position
        self.playing = playing
        hostTime = 0
        base = Atomic(sampleTime)
    }

    private init(pending position: Int64, hostTime: UInt64, playing: Bool) {
        self.position = position
        self.playing = playing
        self.hostTime = hostTime
        base = Atomic(Self.unlatched)
    }

    /// 待钉：第一个渲染块按自己的时间戳钉。`hostTime` 是发布这一刻（`mach_absolute_time()`），离线渲染传 0。
    static func pending(position: Int64, hostTime: UInt64, playing: Bool) -> PlaybackAnchor {
        PlaybackAnchor(pending: position, hostTime: hostTime, playing: playing)
    }

    /// 钉好的那一拍的采样时间；还没钉上是 nil。
    var sampleTime: Int64? {
        let value = base.load(ordering: .relaxed)
        return value == Self.unlatched ? nil : value
    }

    /// 渲染块调：这一拍（第一帧的采样时间 `sampleTime`、这一帧出声卡的 host 时间 `hostTime`）在时间线的第几帧。
    /// 待钉的锚点在这里钉上：同一拍里各轨拿到的时间戳一样，谁先到谁钉、钉出来的数相同。
    func position(sampleTime: Int64, hostTime: UInt64) -> Int64 {
        var start = base.load(ordering: .relaxed)
        if start == Self.unlatched {
            // 时间戳里没带 host 时间（不该发生在真声卡上）就按此刻算，别让播放头在钉上那一下往回跳。
            let candidate = sampleTime - framesElapsed(until: hostTime != 0 ? hostTime : mach_absolute_time())
            let (exchanged, original) = base.compareExchange(expected: Self.unlatched, desired: candidate, ordering: .relaxed)
            start = exchanged ? candidate : original
        }
        return position + (sampleTime - start)
    }

    /// 从发布到 `host` 这一刻过去了多少帧（不按 host 时间走、或者 `host` 比发布还早就是 0）。
    func framesElapsed(until host: UInt64) -> Int64 {
        guard hostTime != 0, host > hostTime else { return 0 }
        return Int64(Double(host - hostTime) * Self.framesPerHostTick)
    }
}

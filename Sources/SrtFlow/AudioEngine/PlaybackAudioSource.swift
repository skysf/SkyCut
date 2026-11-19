import Foundation

// MARK: - 声音引擎在时钟眼里的样子
//
// 管什么：`PlayerClock` 驱动引擎只经这几个方法（`TimelineAudioEngine` 实现它）。单独一个文件、不依赖任何东西：
// 时钟的自检（check-player-clock.sh）只编这一个小文件，不必把整个引擎编进去。
// 挂上它之后**声音是主时钟**：播放头从它读，画面和它一起开播（docs/architecture/playback-start.md），播放中画面差了
// 就调画面的速度追上它（VideoDriftCheck，docs/architecture/audio-engine.md）。

protocol PlaybackAudioSource: AnyObject {
    /// 此刻播放头在时间线的第几秒。
    var playhead: Double { get }
    var isPlaying: Bool { get }
    /// 时间线总长（秒）；0 = 不知道。播放头走到这儿这一轮就播完了：**由时钟按它收尾**（PlayerClock.finishAtEnd），
    /// 不等播放器的「播到头」通知 —— 通知会晚到、会排着队等到下一轮才被处理，到了头的播放器也不会再发第二次。
    var duration: Double { get }
    /// 开播前和播放中检查渲染图；被系统停掉时恢复，返回是否重启过。失败交给时钟停播，不能拿停住的时间反复对表。
    @discardableResult func recoverIfNeeded() throws -> Bool
    func play(from seconds: Double)
    func pause()
    func seek(to seconds: Double)
    /// False while the output is not rendering: stopped by the idle rule, or started and not yet rendered. Play then
    /// waits for it with sound and picture held, and pins the sound to the picture's start
    /// (`play(from:alignedToHostTime:)`, docs/architecture/playback-start.md).
    var isRendering: Bool { get }
    /// Plays from `seconds` as of host time `host` (the picture's start): the first render places the sound at
    /// `seconds` plus the time since `host`, so a stall before that render cannot separate it from the picture.
    func play(from seconds: Double, alignedToHostTime host: UInt64)
}

extension PlaybackAudioSource {
    var isRendering: Bool { true }
    func play(from seconds: Double, alignedToHostTime host: UInt64) { play(from: seconds) }
}

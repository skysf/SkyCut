import Foundation

// MARK: - 照空闲的规矩停图 / 起图
//
// 管什么：拿着一个引擎（`IdleSuspendableAudio`），按 `AudioEngineIdlePolicy` 决定此刻图该不该开着，该停就 `suspend()`、
// 该起就 `wake()`。什么时候看一眼：
//   - 换了配置之后（`reconcile()`，PreviewAudioEngineHost.apply 调）：没有声音了当场停；
//   - 用户回到 SkyCut（切过来、动鼠标、按键：`userReturned()`）：停着的先在后台起好，等他按播放；
//   - 图开着的时候每 `checkEvery` 秒看一次：停着、也没人用够久了就停。图停着的时候不留计时器。
// 不管什么：规矩本身（AudioEngineIdlePolicy）；图怎么停怎么起（TimelineAudioEngine）；用户动没动（AppUserPresence）。
//
// 时间和「用户上一次动是什么时候」都由外面给（`now` / `lastInput`）：自检把它们换成自己拨的钟，不用真等 2 分钟。

/// 能被空闲规矩停掉 / 起回来的声音引擎（`TimelineAudioEngine`；自检里是假的）。
@MainActor
protocol IdleSuspendableAudio: AnyObject {
    /// 时间线上有没有要出声的段。
    var hasSound: Bool { get }
    var isPlaying: Bool { get }
    /// 上一次从在播变成停着是什么时候（和 `now` 同一个钟）；没播过是 nil。
    var stoppedPlayingAt: TimeInterval? { get }
    /// 图是不是故意停着。
    var isSuspended: Bool { get }
    /// 图在跑或者正在起。既不是这个、也不是故意停着（从没起过、收掉了）时没有东西可管。
    var graphIsUp: Bool { get }
    func suspend()
    func wake()
    /// 图要起回来了（不管是谁叫的：这里、还是时钟开播）。
    var onWake: (() -> Void)? { get set }
    /// 后台那一次没起来（没有能用的输出设备）：图还是故意停着。
    var onWakeFailed: (() -> Void)? { get set }
}

extension TimelineAudioEngine: IdleSuspendableAudio {}

@MainActor
final class AudioEngineIdleKeeper {
    let policy: AudioEngineIdlePolicy
    /// 图开着的时候隔多久看一次该不该停。
    let checkEvery: TimeInterval
    private let now: () -> TimeInterval
    private let lastInput: () -> TimeInterval?
    /// 停图 / 起图各记一句（生产里进卡顿日志，带时刻：对着 `pmset -g assertions` 看得出是哪一下）。
    private let note: (String) -> Void
    private weak var audio: (any IdleSuspendableAudio)?
    private var timer: Timer?
    /// 计时器上着没有（自检看：图开着的时候它得一直上着，不然没人在两分钟后停图）。
    var isArmed: Bool { timer != nil }
    /// 上一次在后台起图没起来（没有能用的输出设备？）。之后「看一眼」不再替它重试 —— 不然用户在场的这两分钟里每 5 秒白起
    /// 一次、白记一句；等用户下一次回来（`userReturned`）再试一次，时钟要出声时引擎自己会当场起、把真的错误报出来。
    private var wakeFailed = false

    /// - Parameters:
    ///   - now: 此刻（和 `lastInput` 同一个钟：系统开机以来的秒）。
    ///   - lastInput: 用户上一次在 SkyCut 里动鼠标 / 键盘的时刻（生产里是 `AppUserPresence.shared.lastInput`）；从没动过是 nil。
    init(policy: AudioEngineIdlePolicy = AudioEngineIdlePolicy(), checkEvery: TimeInterval = 5,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         lastInput: @escaping () -> TimeInterval?, note: @escaping (String) -> Void = { _ in }) {
        self.policy = policy
        self.checkEvery = checkEvery
        self.now = now
        self.lastInput = lastInput
        self.note = note
    }

    /// 接手一个引擎（刚建好、图已经起了）：马上看一眼，用不着就停。
    func keep(_ audio: any IdleSuspendableAudio) {
        self.audio = audio
        wakeFailed = false
        audio.onWake = { [weak self] in
            self?.note("预览的音频引擎：起图（要出声了）")
            self?.arm()
        }
        audio.onWakeFailed = { [weak self] in
            self?.wakeFailed = true
            self?.note("预览的音频引擎：图没起来（没有能用的输出设备？），等用户下一次回来或者按播放再试")
            self?.disarm()
        }
        reconcile()
    }

    /// 引擎收掉了。
    func release() {
        audio?.onWake = nil
        audio?.onWakeFailed = nil
        audio = nil
        disarm()
    }

    /// 用户回到 SkyCut 动了一下（上一次没起来的话，这一下再试一次）。
    func userReturned() {
        wakeFailed = false
        reconcile()
    }

    /// 不等空闲时长、当场停图，而且不再自己看（直到用户回来 / 开播把图叫起来）。进程内冒烟量「停过之后第一次播放」用：
    /// 等 2 分钟太慢，光停引擎的话下一次「看一眼」又会因为刚有人用过把它起回来。
    func suspendNow() {
        audio?.suspend()
        disarm()
    }

    /// 此刻图该不该开着，不对就改过来。
    func reconcile() {
        guard let audio else { return disarm() }
        // 上一次「有人要用声音」：刚播完，或者用户在 App 里动过。
        let wanted = max(audio.stoppedPlayingAt ?? -.infinity, lastInput() ?? -.infinity)
        let shouldRun = policy.shouldRun(hasSound: audio.hasSound, isPlaying: audio.isPlaying, quietFor: now() - wanted)
        if shouldRun, audio.isSuspended {
            if !wakeFailed { audio.wake() }   // onWake 里重新上计时器
        } else if !shouldRun, audio.graphIsUp {
            audio.suspend()
            // 只在真的停下来时记一句（图本来就没在跑的话 suspend 什么都不做）。
            if audio.isSuspended {
                note(audio.hasSound ? "预览的音频引擎：停着没人用，停图（声卡放手）" : "预览的音频引擎：时间线没有声音，停图（声卡放手）")
            }
        }
        // 图在跑（或者正在起）才留着计时器：故意停着、没起来、收掉了都不用再看。
        if audio.graphIsUp { arm() } else { disarm() }
    }

    /// 图开着：隔一会儿看一次。
    private func arm() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: checkEvery, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.reconcile() }
        }
        timer.tolerance = checkEvery / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
    }
}

import AVFoundation
import Foundation
import SrtFlowCore

// 第 15 组：预览的音频引擎不是一直开着的（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。
//
// 四层：
//   1. 规矩本身（AudioEngineIdlePolicy，纯值）：没有声音不开、在播开着、停着 2 分钟没人用就停。
//   2. 照规矩办事的那一位（AudioEngineIdleKeeper）：假引擎 + 自己拨的钟，不用真等 2 分钟；外加一遍真计时器
//      （空闲时长注成 0.1 秒）：没人叫它，图自己停；停着的时候计时器不再跑。
//   3. 引擎的停 / 起（IdleEngine.swift；手动渲染，CI 没有声卡也跑）：停了之后节点、播放头、播放状态都在；停着 seek 不起图；时钟开播时
//      当场起、从原处开播、一帧不跳（不指望采样时间从 0 重来）；用户回来了先在后台起；没有声音的时间线不起图。
//   4. 真声卡（开发机，--realtime-idle，全程静音，IdleRealtime.swift）：停了之后图真的不跑；冷着按播放等声卡起来、
//      从原处开播、开头的声音不跳过；先动一下再按播放不用等；没有声音的时间线播着图也不起、播放头按 host 时间走；
//      停过再起总表的 tap 还在。
// 量「停过之后第一次播放多等多久」：--measure-idle（Measure.swift）。编译方式见 scripts/check-audio-engine.sh。

// MARK: - 1. 规矩

func checkIdlePolicy() {
    let policy = AudioEngineIdlePolicy()
    check(policy.idleAfter == 120, "停着没人用 2 分钟停图（用户 2026-11-11 定的数：先定的 30 秒，看过量出来的数改成 2 分钟）")
    check(!policy.shouldRun(hasSound: false, isPlaying: false, quietFor: 0), "没有声音：停着不开")
    check(!policy.shouldRun(hasSound: false, isPlaying: true, quietFor: 0), "没有声音：在播也不开（播放头按 host 时间走）")
    check(policy.shouldRun(hasSound: true, isPlaying: true, quietFor: .infinity), "有声音、在播：开着，不管多久没人动")
    check(policy.shouldRun(hasSound: true, isPlaying: false, quietFor: 0), "有声音、停着、刚有人用：开着")
    check(policy.shouldRun(hasSound: true, isPlaying: false, quietFor: 119.9), "有声音、停着、119.9 秒前有人用：还开着")
    check(!policy.shouldRun(hasSound: true, isPlaying: false, quietFor: 120), "有声音、停着、2 分钟没人用：停")
    let short = AudioEngineIdlePolicy(idleAfter: 0.5)
    check(short.shouldRun(hasSound: true, isPlaying: false, quietFor: 0.4) && !short.shouldRun(hasSound: true, isPlaying: false, quietFor: 0.5),
          "时长注成别的数照那个数算（自检注短的，不用真等）")
    check(!policy.shouldRun(hasSound: true, isPlaying: false, quietFor: .infinity), "有声音、停着、从来没人用：停")
    check(!AudioEngineConfig.empty.hasSound, "空配置没有声音")
}

// MARK: - 2. 照规矩办事

@MainActor
final class FakeIdleAudio: IdleSuspendableAudio {
    /// 图的样子：在跑、故意停着、既不在跑也不算停着（从没起来过 / 收掉了）。
    enum Graph { case running, suspended, stopped }

    var hasSound = true
    var graph = Graph.running
    /// 起图起不来（没有能用的输出设备）。
    var wakeFails = false
    /// 这一下停不下来（图其实已经不在跑了，只是状态还没跟上）。
    var refusesSuspend = false
    var onWake: (() -> Void)?
    var onWakeFailed: (() -> Void)?
    private(set) var suspends = 0
    private(set) var wakes = 0
    /// 被问了几次（看计时器还在不在跑）。
    private(set) var polls = 0
    private var playing = false
    private(set) var stoppedPlayingAt: TimeInterval?

    var isSuspended: Bool { graph == .suspended }
    var graphIsUp: Bool { graph == .running }

    var isPlaying: Bool {
        polls += 1
        return playing
    }

    /// `at`：这一下发生在什么时候（停下来的那一刻记成「上一次停止播放」）。
    func setPlaying(_ playing: Bool, at time: TimeInterval) {
        if self.playing, !playing { stoppedPlayingAt = time }
        self.playing = playing
    }

    /// 和真引擎一样：图没在跑就什么都不做。
    func suspend() {
        guard graph == .running, !refusesSuspend else { return }
        graph = .suspended
        suspends += 1
    }

    /// 和真引擎一样：只起故意停着的；起不来就还是停着、叫一声 onWakeFailed。
    func wake() {
        guard graph == .suspended else { return }
        wakes += 1
        onWake?()
        if wakeFails { onWakeFailed?() } else { graph = .running }
    }
}

@MainActor
func checkIdleKeeper() {
    var clock = 1_000.0
    var input: TimeInterval? = 1_000.0   // 用户刚在 App 里动过（打开工程的那一下）
    /// 规矩里的空闲时长（2 分钟）：下面拨钟按它拨「差 1 秒不到」和「过了 1 秒」，不写死。
    let idleAfter = AudioEngineIdlePolicy().idleAfter
    // checkEvery 给得很大：这一段每一步都自己叫 reconcile，不靠计时器。
    func keeper() -> AudioEngineIdleKeeper {
        AudioEngineIdleKeeper(checkEvery: 3_600, now: { clock }, lastInput: { input })
    }

    do {
        let audio = FakeIdleAudio()
        let idle = keeper()
        idle.keep(audio)
        check(!audio.isSuspended, "刚有人用过：接手之后图留着")
        clock += idleAfter - 1
        idle.reconcile()
        check(!audio.isSuspended, "停着差 1 秒不到 2 分钟：图还开着")
        clock += 2
        idle.reconcile()
        check(audio.isSuspended && audio.suspends == 1, "停着过了 2 分钟没人用：图停了")
        idle.reconcile()
        check(audio.suspends == 1, "已经停着就不再停一次")

        input = clock
        idle.userReturned()
        check(!audio.isSuspended && audio.wakes == 1, "用户回来动了一下：图起回来（等他按播放）")

        audio.setPlaying(true, at: clock)
        clock += 600
        idle.reconcile()
        check(!audio.isSuspended, "在播：十分钟没人动也不停")
        audio.setPlaying(false, at: clock)
        clock += idleAfter - 1
        idle.reconcile()
        check(!audio.isSuspended, "刚播完、差 1 秒不到 2 分钟：还开着（从停止播放那一刻起算）")
        clock += 2
        idle.reconcile()
        check(audio.isSuspended && audio.suspends == 2, "播完过了 2 分钟没人用：停")

        // 时钟开播时引擎自己起图（不经这里），只播了 2 秒就停 —— 夹在两次「看一眼」之间，这里从没看见它在播：
        // 照样从停的那一刻起算 2 分钟，不能因为「上一次有人动是很久以前」当场停掉。
        audio.setPlaying(true, at: clock)
        audio.wake()
        check(!audio.isSuspended, "前提：引擎自己把图起回来了")
        clock += 2
        audio.setPlaying(false, at: clock)
        clock += 3
        idle.reconcile()
        check(!audio.isSuspended, "引擎自己起回来、短短播了 2 秒：停下 3 秒，图还开着")
        clock += idleAfter - 2
        idle.reconcile()
        check(audio.isSuspended && audio.suspends == 3, "引擎自己起回来的图，播完过了 2 分钟照样停")
        idle.release()
    }

    do {
        let audio = FakeIdleAudio()
        audio.hasSound = false
        input = clock
        let idle = keeper()
        idle.keep(audio)
        check(audio.isSuspended, "没有声音的时间线：接手当场停，哪怕刚有人用过")
        idle.userReturned()
        check(audio.isSuspended && audio.wakes == 0, "没有声音：用户回来也不起")
        audio.setPlaying(true, at: clock)
        idle.reconcile()
        check(audio.isSuspended && audio.wakes == 0, "没有声音：在播也不起")
        audio.setPlaying(false, at: clock)
        audio.hasSound = true
        idle.reconcile()
        check(!audio.isSuspended && audio.wakes == 1, "换了配置有声音了、用户正在用：起好")
        audio.hasSound = false
        idle.reconcile()
        check(audio.isSuspended, "换了配置没有声音了：当场停，不等 2 分钟")
        idle.release()
    }

    do {
        let audio = FakeIdleAudio()
        input = nil
        let idle = keeper()
        idle.keep(audio)
        check(audio.isSuspended, "从来没人在 App 里动过（AI 在后面开的工程）：接手当场停")
        idle.release()
        input = clock
        idle.userReturned()
        check(audio.wakes == 0, "引擎收掉之后不再碰它")
    }

    // 后台起图没起来（没有能用的输出设备）：不每看一眼就重试一次、不记「停图」、不留计时器；用户下一次回来再试一次。
    // 2026-11-11 审查之前：状态回到「没在跑也不算停着」，管空闲的每 5 秒记一句「停图」。
    do {
        var notes: [String] = []
        let audio = FakeIdleAudio()
        audio.graph = .suspended
        audio.wakeFails = true
        input = clock
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { clock }, lastInput: { input }, note: { notes.append($0) })
        idle.keep(audio)
        check(audio.wakes == 1 && audio.isSuspended, "前提：用户在场、图停着 → 试着起了一次，没起来")
        for _ in 0..<3 {
            clock += 5
            idle.reconcile()
        }
        check(audio.wakes == 1, "没起来之后看了三眼：没有再试（试了 \(audio.wakes) 次）")
        check(notes.filter { $0.contains("停图") }.isEmpty, "没起来之后不记「停图」（记了 \(notes)）")
        check(notes.filter { $0.contains("没起来") }.count == 1, "没起来只记一句（记了 \(notes)）")
        input = clock
        idle.userReturned()
        check(audio.wakes == 2, "用户下一次回来：再试一次")
        audio.wakeFails = false
        clock += 5
        input = clock
        idle.userReturned()
        check(audio.wakes == 3 && audio.graphIsUp, "设备回来了：这一次起得来")
        idle.release()
    }

    // 图既不在跑也不算停着（收掉了 / 从没起来过）：suspend 什么都不做，就不该记「停图」。
    do {
        var notes: [String] = []
        let audio = FakeIdleAudio()
        audio.graph = .stopped
        audio.hasSound = false
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { clock }, lastInput: { input }, note: { notes.append($0) })
        idle.keep(audio)
        for _ in 0..<3 {
            clock += 5
            idle.reconcile()
        }
        check(notes.isEmpty && audio.suspends == 0, "图本来就没在跑：不记「停图」（记了 \(notes)）")
        idle.release()
    }

    // 该停、叫了 suspend、可这一下没停下来：不记「停图」（只在真的从开着变成停着时记）。
    do {
        var notes: [String] = []
        let audio = FakeIdleAudio()
        audio.refusesSuspend = true
        input = nil
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { clock }, lastInput: { input }, note: { notes.append($0) })
        idle.keep(audio)
        idle.reconcile()
        check(notes.isEmpty, "没真的停下来：不记「停图」（记了 \(notes)）")
        audio.refusesSuspend = false
        idle.reconcile()
        check(notes.count == 1 && audio.isSuspended, "真的停下来了：记一句（记了 \(notes)）")
        idle.release()
        input = clock
    }

    // 同一种样子 + 真计时器：没有东西可管，不留计时器（之前每 5 秒白看一次、白记一句）。
    do {
        let audio = FakeIdleAudio()
        audio.graph = .stopped
        let idle = AudioEngineIdleKeeper(policy: AudioEngineIdlePolicy(idleAfter: 0.01), checkEvery: 0.02, lastInput: { nil })
        idle.keep(audio)
        let polls = audio.polls
        pumpMain(seconds: 0.15)
        check(audio.polls == polls, "真计时器：图本来就没在跑，不留计时器（又问了 \(audio.polls - polls) 次）")
        idle.release()
    }

    // 真计时器 + 起不来：起不来之后不留计时器（之前计时器一直转、每一下都再记一句）。
    do {
        let audio = FakeIdleAudio()
        audio.graph = .suspended
        audio.wakeFails = true
        let started = ProcessInfo.processInfo.systemUptime
        let idle = AudioEngineIdleKeeper(checkEvery: 0.02, lastInput: { started })
        idle.keep(audio)
        let polls = audio.polls
        pumpMain(seconds: 0.15)
        check(audio.wakes == 1 && audio.polls == polls, "真计时器：起不来之后不再看、不再试（又问了 \(audio.polls - polls) 次，试了 \(audio.wakes) 次）")
        idle.release()
    }

    // 真计时器：没人叫 reconcile，图自己停；停着的时候不再问。
    do {
        let audio = FakeIdleAudio()
        let started = ProcessInfo.processInfo.systemUptime
        let idle = AudioEngineIdleKeeper(policy: AudioEngineIdlePolicy(idleAfter: 0.1), checkEvery: 0.02, lastInput: { started })
        idle.keep(audio)
        check(!audio.isSuspended, "真计时器：刚接手还开着")
        pumpMain(until: { audio.isSuspended })
        check(audio.isSuspended, "真计时器：空闲时长一过，没人叫也自己停")
        let polls = audio.polls
        pumpMain(seconds: 0.15)
        check(audio.polls == polls, "图停着的时候不留计时器（停着又问了 \(audio.polls - polls) 次）")
        audio.setPlaying(true, at: ProcessInfo.processInfo.systemUptime)
        audio.wake()   // 时钟开播：引擎自己起图
        pumpMain(seconds: 0.25)
        check(!audio.isSuspended, "真计时器：在播不停")
        audio.setPlaying(false, at: ProcessInfo.processInfo.systemUptime)
        pumpMain(until: { audio.isSuspended })
        check(audio.isSuspended, "真计时器：引擎自己起回来之后计时器重新上了，播完照样停")
        idle.release()
    }
}

func pumpMain(seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 泵主循环直到条件成立（最多 5 秒；超时由后面的断言报）。
func pumpMain(until done: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !done(), ProcessInfo.processInfo.systemUptime < deadline { pumpMain(seconds: 0.01) }
}

/// 等后台那一次起图做完（最多 5 秒）。
func waitRunning(_ audio: TimelineAudioEngine) {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while audio.graphState == .starting, ProcessInfo.processInfo.systemUptime < deadline { usleep(500) }
}

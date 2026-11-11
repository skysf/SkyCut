import AVFoundation
import Foundation
import SrtFlowCore

// 第 15 组：预览的音频引擎不是一直开着的（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。
//
// 四层：
//   1. 规矩本身（AudioEngineIdlePolicy，纯值）：没有声音不开、在播开着、停着 2 分钟没人用就停。
//   2. 照规矩办事的那一位（AudioEngineIdleKeeper）：假引擎 + 自己拨的钟，不用真等 2 分钟；外加一遍真计时器
//      （空闲时长注成 0.1 秒）：没人叫它，图自己停；停着的时候计时器不再跑。
//   3. 引擎的停 / 起（手动渲染，CI 没有声卡也跑）：停了之后节点、播放头、播放状态都在；停着 seek 不起图；时钟开播时
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
private final class FakeIdleAudio: IdleSuspendableAudio {
    var hasSound = true
    var isSuspended = false
    var onWake: (() -> Void)?
    private(set) var suspends = 0
    private(set) var wakes = 0
    /// 被问了几次（看计时器还在不在跑）。
    private(set) var polls = 0
    private var playing = false
    private(set) var stoppedPlayingAt: TimeInterval?

    var isPlaying: Bool {
        polls += 1
        return playing
    }

    /// `at`：这一下发生在什么时候（停下来的那一刻记成「上一次停止播放」）。
    func setPlaying(_ playing: Bool, at time: TimeInterval) {
        if self.playing, !playing { stoppedPlayingAt = time }
        self.playing = playing
    }

    func suspend() {
        isSuspended = true
        suspends += 1
    }

    func wake() {
        isSuspended = false
        wakes += 1
        onWake?()
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

// MARK: - 3. 引擎的停 / 起（手动渲染）

func checkEngineIdle(tone: URL) {
    let quantum = 1024.0 / TimelineAudioEngine.sampleRate
    let frame = 1 / TimelineAudioEngine.sampleRate
    do {
        let config = AudioEngineConfig.make(from: plainLane(tone))
        check(config.hasSound, "前提：这条时间线有声音")
        let audio = try TimelineAudioEngine(config: config, mode: .offline)
        defer { audio.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: TimelineAudioEngine.format, frameCapacity: 1024)!
        func render(_ count: Int) throws {
            for _ in 0..<count {
                let status = try audio.engine.renderOffline(1024, to: buffer)
                check(status == .success, "空闲回归的原生图渲染成功")
            }
        }
        check(try audio.recoverIfNeeded(), "前提：图起来了")
        check(audio.graphState == .running, "起来之后状态是在跑")
        audio.play(from: 1)
        try render(8)
        // 手动渲染的时间戳带着一个很早的 host 时间：播放头读数里「这一拍已经过去多少」那一截封顶补两拍，
        // 所以渲了 N 拍读到的是「起点 + (N − 1) 拍 + 2 拍」（和第 14 组读到的是同一种读数）。
        check(abs(audio.playhead - (1 + 9 * quantum)) < frame, "前提：播了 8 拍，播放头在 \(1 + 9 * quantum)，实测 \(audio.playhead)")

        // 停着：停图。
        audio.pause()
        let pausedAt = audio.playhead
        audio.suspend()
        check(audio.isSuspended && !audio.engine.isRunning, "suspend 之后原生图真的不跑了")
        check(!audio.isPlaying && audio.playhead == pausedAt, "停图不动播放头、不改播放状态")
        audio.suspend()
        check(audio.isSuspended, "停着再停一次没事")
        audio.seek(to: 2.5)
        check(audio.playhead == 2.5 && audio.isSuspended && !audio.engine.isRunning, "停着 seek：播放头过去了，图不起")

        // 时钟开播：故意停着、有声音 —— 那一问当场把图起起来（等声卡），再从原处开播。
        check(try !audio.recoverIfNeeded(), "故意停着的图起回来不算「恢复」（时钟不用重新对画面）")
        check(audio.graphState == .running && audio.engine.isRunning, "有声音：开播前那一问回来时图已经在跑（不让播放头先空走一截）")
        audio.play(from: 2.5)
        check(audio.isPlaying && abs(audio.playhead - 2.5) < frame, "开播：播放头在起点")
        check(try !audio.recoverIfNeeded(), "起好之后每拍再问一次：什么都不做")
        try render(4)
        check(abs(audio.playhead - (2.5 + 5 * quantum)) < frame,
              "停过再起：播放头从原处接着走、一帧不跳（该在 \(2.5 + 5 * quantum)，实测 \(audio.playhead)）")
        try render(4)
        check(abs(audio.playhead - (2.5 + 9 * quantum)) < frame, "再渲 4 拍接着走，实测 \(audio.playhead)")

        // 播着停图（配置换成没有声音的那种情况）：播放状态还在，起回来接着走。
        audio.suspend()
        let suspendedAt = audio.playhead
        check(audio.isPlaying && audio.isSuspended && !audio.engine.isRunning, "播着停图：还算在播，图不跑")
        check(abs(suspendedAt - (2.5 + 9 * quantum)) < frame, "播着停图：位置不跳，实测 \(suspendedAt)")
        check(try !audio.recoverIfNeeded(), "播着、图停着、有声音：每拍那一问把图起起来")
        check(audio.graphState == .running && audio.engine.isRunning, "播着起回来：图在跑")
        try render(4)
        check(abs(audio.playhead - (suspendedAt + 5 * quantum)) < frame,
              "播着停过再起：从停的地方接着走（该在 \(suspendedAt + 5 * quantum)，实测 \(audio.playhead)）")

        // 停着换配置：还停着。用户回来了（wake）：在后台起、马上回来；起到一半时钟来问，等它起完。
        audio.pause()
        audio.suspend()
        audio.replace(config: AudioEngineConfig.make(from: fadedLane(tone)))
        check(audio.isSuspended && !audio.engine.isRunning, "停着换整份配置：图还停着")
        audio.wake()
        check(audio.graphState == .starting || audio.graphState == .running, "wake：在后台起（不等它）")
        check(try !audio.recoverIfNeeded(), "后台正在起的时候时钟来问：等它起完，不算恢复")
        check(audio.graphState == .running && audio.engine.isRunning, "等完之后图在跑")
        audio.wake()
        check(audio.graphState == .running, "在跑的图 wake 一下没事")
        audio.pause()
        audio.suspend()
        audio.wake()
        waitRunning(audio)
        check(audio.graphState == .running && audio.engine.isRunning, "没人来问，后台那一次自己也起得完")
    } catch {
        check(false, "引擎空闲回归失败：\(error)")
    }

    // 没有声音的时间线：图停着就不起，开播也不起。
    do {
        let audio = try TimelineAudioEngine(config: .empty, mode: .offline)
        defer { audio.stop() }
        check(try audio.recoverIfNeeded(), "前提：空时间线的图起来了")
        audio.suspend()
        check(try !audio.recoverIfNeeded(), "没有声音：开播前那一问不起图")
        audio.play(from: 4)
        check(try !audio.recoverIfNeeded(), "没有声音：播着每拍那一问也不起图")
        check(audio.isSuspended && !audio.engine.isRunning && audio.isPlaying, "没有声音的时间线播着，图一直停着")
        audio.replace(config: AudioEngineConfig.make(from: plainLane(tone)))
        check(try !audio.recoverIfNeeded(), "换成有声音的配置：下一问把图起起来")
        check(audio.graphState == .running && audio.engine.isRunning, "有声音了：图起来了")
    } catch {
        check(false, "没有声音的时间线回归失败：\(error)")
    }
}

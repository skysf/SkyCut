import AVFoundation
import Foundation

// 主时钟的生命周期和恢复：用可控的声音时钟驱动真实 PlayerClock / AVPlayer / Timer。
// 不验证原生音频图；图停掉后的重启与时间连续性由 AudioEngine/Recovery.swift 验证。
private final class RecoverableAudioSource: PlaybackAudioSource {
    enum Failure: Error { case unavailable }
    private var position = 0.0
    private var host = ProcessInfo.processInfo.systemUptime
    private(set) var isPlaying = false
    private(set) var stopped = false
    private(set) var recoveries = 0
    private(set) var attempts = 0
    var canRecover = true
    var recoveryDelay = 0.0
    /// 时间线总长（0 = 不知道）：时钟按它收尾。
    var duration = 0.0

    var playhead: Double {
        position + (isPlaying && !stopped ? ProcessInfo.processInfo.systemUptime - host : 0)
    }

    func interrupt() {
        position = playhead
        stopped = true
    }

    func recoverIfNeeded() throws -> Bool {
        attempts += 1
        guard stopped else { return false }
        guard canRecover else { throw Failure.unavailable }
        if recoveryDelay > 0 { Thread.sleep(forTimeInterval: recoveryDelay) }
        stopped = false
        host = ProcessInfo.processInfo.systemUptime
        recoveries += 1
        return true
    }

    func play(from seconds: Double) {
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
        isPlaying = true
    }

    func pause() {
        position = playhead
        isPlaying = false
    }

    func seek(to seconds: Double) {
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
    }
}

private func pumpAudioClock(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func waitForAudioClock(until done: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !done(), ProcessInfo.processInfo.systemUptime < deadline { pumpAudioClock(0.02) }
}

func checkAudioSourceRecovery(clip: URL) {
    let clock = PlayerClock(observationInterval: 0.02)
    clock.player.isMuted = true
    clock.attachItem(AVPlayerItem(url: clip))
    waitForAudioClock { clock.player.currentItem?.status == .readyToPlay }
    check(clock.player.currentItem?.status == .readyToPlay, "声音时钟回归的真实视频已就绪")

    let old = RecoverableAudioSource()
    clock.attachAudioSource(old)
    clock.seek(to: 2)
    old.interrupt()
    clock.play()
    check(old.recoveries == 1, "开播前恢复已经停掉的声音图")
    waitForAudioClock { clock.time > 2.1 }
    check(clock.time > 2.1, "恢复后播放头继续向前，实测 \(clock.time)")

    // 恢复可能耗过原来的整个 200 ms 窗口：等待真实状态，再单独验证恢复后的推进。
    // 延迟只在假声音源里，仍由生产的 Timer / recoverAudioIfNeeded 驱动。
    old.recoveryDelay = 0.25
    old.interrupt()
    let interruptedAt = clock.time
    waitForAudioClock { old.recoveries == 2 }
    check(old.recoveries == 2, "播放途中声音图停掉也会恢复，实测 \(old.recoveries) 次")
    waitForAudioClock { clock.time > interruptedAt + 0.1 }
    check(clock.time > interruptedAt + 0.1, "中断恢复后播放头继续向前，停止于 \(interruptedAt)，实测 \(clock.time)")
    old.recoveryDelay = 0

    old.canRecover = false
    old.interrupt()
    waitForAudioClock { !clock.isPlaying && !old.isPlaying }
    check(!clock.isPlaying && !old.isPlaying, "恢复失败明确暂停画面和声音")
    let attempts = old.attempts
    pumpAudioClock(0.1)
    check(old.attempts == attempts, "恢复失败后不每拍反复重试")
    old.canRecover = true
    clock.play()
    let retryFrom = clock.time
    waitForAudioClock { old.isPlaying && old.recoveries == 3 && clock.time > retryFrom + 0.1 }
    check(old.isPlaying && old.recoveries == 3 && clock.time > retryFrom + 0.1,
          "再次点击播放可以重试恢复并继续推进，实测 \(old.recoveries) 次、\(clock.time) 秒")

    let replacement = RecoverableAudioSource()
    clock.attachAudioSource(replacement)
    check(clock.audioSource === replacement, "新的声音引擎替换旧主时钟")
    check(!old.isPlaying, "替换时旧主时钟停止")
    clock.detach()
    check(clock.audioSource == nil, "卸片彻底摘掉声音主时钟")
    replacement.play(from: 40)
    pumpAudioClock(0.1)
    check(clock.time == 0, "已摘掉的计时器不能把旧声音时间写回播放头")
    replacement.pause()

    // 同一工程关预览再打开时可能复用引擎：摘掉以后同一个实例也能重新接上。
    clock.attachItem(AVPlayerItem(url: clip))
    clock.attachAudioSource(replacement)
    clock.seek(to: 6)
    clock.play()
    waitForAudioClock { clock.time > 6.1 }
    check(clock.time > 6.1, "重新接上声音时钟后，新预览能正常播放")
    clock.detach()
}

/// 播到头由声音主时钟自己收尾（PlayerClock.finishAtEnd）：2026-11-11 之前没人收尾 —— 播放器播到头自己停，声音主时钟的
/// 锚点还标着在播，播放头照着它一直往后走，引擎也永远不算停着、图一直开着占着声卡
/// （docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。素材是 60 秒的真视频、真 AVPlayer；从 59.6 秒起播。
func checkAudioSourceStopsAtEnd(clip: URL) {
    let clock = PlayerClock(observationInterval: 0.02)
    clock.player.isMuted = true
    clock.attachItem(AVPlayerItem(url: clip))
    waitForAudioClock { clock.player.currentItem?.status == .readyToPlay }
    let source = RecoverableAudioSource()
    source.duration = 60
    clock.attachAudioSource(source)
    clock.seek(to: 59.6)
    clock.play()
    waitForAudioClock { clock.isPlaying && source.isPlaying }
    check(clock.isPlaying && source.isPlaying, "前提：片尾前 0.4 秒开播，画面和声音时钟都在播")
    waitForAudioClock { !source.isPlaying && !clock.isPlaying }
    check(!source.isPlaying, "播到头：声音主时钟自己停")
    check(!clock.isPlaying, "播到头：画面也停了")
    check(clock.time == 60 && source.playhead == 60, "播到头：播放头钉在总长上，不多不少（时钟 \(clock.time)，声音源 \(source.playhead)）")
    pumpAudioClock(0.2)
    check(clock.time == 60, "播到头之后播放头不再往后走（0.2 秒后 \(clock.time)）")

    // 在尽头不 seek、直接再按播放：没有东西可播，这一下不开播。到了头的播放器不会再报一次「播完了」，
    // 开播的话声音主时钟从尽头起步、带着播放头越过片尾一直走（审查复现：rate 0、声音源在播、播放头 2.34 → 3.20）。
    clock.play()
    pumpAudioClock(0.35)
    check(!source.isPlaying, "在尽头直接再按播放：声音主时钟不开播")
    check(clock.time == 60 && clock.player.rate == 0, "在尽头直接再按播放：播放头还在总长上、画面没动（时钟 \(clock.time)）")

    // 在尽头悬停着（画面在别处扫帧）按播放：什么都不发生，悬停预览也照旧留着。
    clock.peek(at: 10)
    clock.togglePlayback()
    pumpAudioClock(0.1)
    check(!source.isPlaying && clock.peekTime == 10 && clock.time == 60, "在尽头悬停着按播放：不开播，悬停预览还在（peek \(String(describing: clock.peekTime))）")
    clock.endPeek()

    // 上一跳的读数略微超出总长（声音时钟最后一次读数比条目长一两毫秒，审查里量到 2.001864）：照样不开播。
    clock.observePlaybackTime(60.002)
    clock.play()
    pumpAudioClock(0.4)
    check(!source.isPlaying, "读数略超总长时再按播放：声音主时钟不开播")
    check(clock.time == 60.002, "读数略超总长时再按播放：播放头没有接着往后走（\(clock.time)）")

    // 停了之后回去再播照样行；用户自己暂停不受影响。
    clock.seek(to: 3)
    clock.play()
    waitForAudioClock { clock.time > 3.1 }
    check(source.isPlaying && clock.time > 3.1, "到头之后回到 3 秒再播，照常走，实测 \(clock.time)")
    clock.pause()
    check(!source.isPlaying, "用户暂停：声音时钟停")

    // 不知道总长（0）的声音源：时钟不替它收尾，也不拦开播。
    source.duration = 0
    clock.seek(to: 59.9)
    clock.play()
    pumpAudioClock(0.3)
    check(source.isPlaying && clock.time > 60, "不知道总长：时钟不替它收尾（\(clock.time)）")
    clock.pause()
    clock.detach()
}

/// 2 秒的真视频（没有音轨）+ 说自己总长 2 秒的声音源：片尾的两种交错（2026-11-11 审查复现的两处）。
func checkAudioSourceEndInterleavings(short: URL) {
    let clock = PlayerClock(observationInterval: 0.02)
    clock.player.isMuted = true
    clock.attachItem(AVPlayerItem(url: short))
    waitForAudioClock { clock.player.currentItem?.status == .readyToPlay }
    check(clock.player.currentItem?.status == .readyToPlay, "片尾交错回归的 2 秒真视频已就绪")
    let source = RecoverableAudioSource()
    source.duration = 2
    clock.attachAudioSource(source)

    // 1. 自然播完 → 不 seek → 再按播放，连着八轮：每一轮都停在总长上，再按一下不开播。
    //    审查里八次里撞上一次（起点 2.001864，350 ms 后 rate 0、声音源在播、播放头 2.34）。
    var stuck = 0, overshoot = 0
    for _ in 0..<8 {
        clock.seek(to: 1.7)
        clock.play()
        waitForAudioClock { !source.isPlaying && !clock.isPlaying }
        if clock.time != 2 { overshoot += 1 }
        clock.play()
        pumpAudioClock(0.2)
        if source.isPlaying || clock.time != 2 { stuck += 1 }
        clock.pause()
    }
    check(overshoot == 0, "自然播完八轮：每一轮播放头都正好钉在总长上（\(overshoot) 轮不是）")
    check(stuck == 0, "自然播完再按播放八轮：声音主时钟一次都没有越过片尾接着走（\(stuck) 轮走了）")

    // 2. 旧一轮「播到头」的通知还排着队，用户已经回退重播：不能把新一轮停掉。
    //    从 1.8 秒播，把主线程占住 0.4 秒（原生播放器这时候播到头、通知排在主队列上），不泵 RunLoop 就回退到 1.6 秒重播。
    //    第一版认通知、拿「播放头在最后半秒里」当它有效：新一轮的声音在 1.6005 秒被停掉，画面还在播（审查复现）。
    clock.seek(to: 1.8)
    clock.play()
    waitForAudioClock { clock.isPlaying && source.isPlaying }
    Thread.sleep(forTimeInterval: 0.4)
    clock.seek(to: 1.6)
    clock.play()
    pumpAudioClock(0.1)
    check(source.isPlaying, "旧的「播到头」通知晚到：新一轮的声音主时钟照样在播")
    check(clock.time > 1.62, "旧的「播到头」通知晚到：新一轮的播放头在走（\(clock.time)）")
    check(clock.player.rate > 0, "旧的「播到头」通知晚到：画面也在播")
    waitForAudioClock { !source.isPlaying && !clock.isPlaying }
    check(!source.isPlaying && clock.time == 2, "新一轮照常播到头、停在总长上（\(clock.time)）")
    clock.detach()
}

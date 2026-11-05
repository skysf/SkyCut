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

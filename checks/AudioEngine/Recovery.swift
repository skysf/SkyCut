import AVFoundation
import Foundation

// 原生渲染图停止后的恢复：默认用 manual rendering，CI 无声卡也必须验证时钟连续性。
// --realtime-recovery 另在开发机上走实际输出设备，始终静音；启动失败必须报失败，不能当作通过。
func checkEngineRecovery() {
    do {
        let audio = try TimelineAudioEngine(config: .empty, mode: .offline)
        defer { audio.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: TimelineAudioEngine.format, frameCapacity: 1024)!
        func render(_ count: Int) throws {
            for _ in 0..<count {
                let status = try audio.engine.renderOffline(1024, to: buffer)
                check(status == .success, "恢复回归的原生图渲染成功")
            }
        }
        try audio.engine.start()
        audio.play(from: 3.5)
        try render(16)
        let before = audio.playhead
        check(before > 3.7, "前提：停止前原生渲染时钟确实推进")
        check(try !audio.recoverIfNeeded(), "正常图不重启")
        audio.engine.stop()  // 模拟系统停图；playing 锚点保持 true。
        check(audio.isPlaying && !audio.engine.isRunning, "前提：播放意图还在，但原生图已经停止")
        check(try audio.recoverIfNeeded(), "停图后确实重启了原生图")
        check(audio.engine.isRunning && audio.isPlaying, "图和播放状态一起恢复")
        check(abs(audio.playhead - before) < 1 / TimelineAudioEngine.sampleRate, "重启不跳回 0、不跳到别的位置")
        try render(4)
        check(audio.playhead > before + 0.04, "原生采样时间归零后，播放头继续推进，不等待追上旧采样数")

        audio.pause()
        audio.seek(to: 9)
        audio.engine.stop()
        check(try audio.recoverIfNeeded(), "停着的图也能恢复")
        try render(4)
        check(!audio.isPlaying && audio.playhead == 9, "恢复保留暂停状态和定位，不擅自开播")
        audio.play(from: 9)
        try render(4)
        check(audio.playhead > 9.04, "暂停恢复后再开播，时钟仍然推进")
    } catch {
        check(false, "原生音频图恢复回归失败：\(error)")
    }
}

func checkRealtimeEngineRecovery() {
    do {
        let audio = try TimelineAudioEngine(config: .empty, mode: .realtime)
        defer { audio.stop() }
        audio.mute()
        try audio.start()
        audio.play(from: 3.5)
        Thread.sleep(forTimeInterval: 0.25)
        let before = audio.playhead
        check(before > 3.65, "真实声卡的时钟推进，实测 \(before)")
        audio.engine.stop()
        let stoppedAt = audio.playhead
        Thread.sleep(forTimeInterval: 0.1)
        check(abs(audio.playhead - stoppedAt) < 0.06, "前提：停图后声音时钟确实停住")
        // 停久一点再恢复：真声卡上重启之后采样时间接着停之前的数往下走（不从 0 重来）。锚点要是按「从 0 起」钉，
        // 播放头会一下跳出去和停的时间一样长（2026-11-11 量到的，之前这里只断言「在往前走」，跳出去也算过）。
        Thread.sleep(forTimeInterval: 1.5)
        check(try audio.recoverIfNeeded(), "真实声卡的渲染图重启")
        Thread.sleep(forTimeInterval: 0.25)
        check(audio.playhead > stoppedAt + 0.15, "真实声卡重启后继续推进，实测 \(audio.playhead)")
        check(audio.playhead < stoppedAt + 0.45, "真实声卡重启后从停的地方接着走、不跳出去（停在 \(stoppedAt)，0.25 秒后实测 \(audio.playhead)）")
    } catch {
        check(false, "真实声卡恢复失败：\(error)")
    }
}

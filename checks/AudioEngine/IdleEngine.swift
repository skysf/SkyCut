import AVFoundation
import Foundation
import SrtFlowCore

// 第 15 组的第 3 层：引擎的停 / 起（手动渲染，CI 没有声卡也跑）。前两层（规矩、照规矩办事）和这一组的来由见 Idle.swift。
//
// 停了之后节点、播放头、播放状态都在，喂样线程歇着；停着 seek 不起图；时钟开播时当场起、从原处开播、一帧不跳（不指望采样
// 时间从 0 重来）；用户回来了先在后台起；后台起图没起来（注一个起不来的图）还是故意停着的样子；没有声音的时间线不起图。

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
        check(audio.feedersResting && !audio.graphIsUp, "图停着：喂样线程歇着（不每 50 ms 醒一次）")
        check(!audio.isPlaying && audio.playhead == pausedAt, "停图不动播放头、不改播放状态")
        audio.suspend()
        check(audio.isSuspended, "停着再停一次没事")
        audio.seek(to: 2.5)
        check(audio.playhead == 2.5 && audio.isSuspended && !audio.engine.isRunning, "停着 seek：播放头过去了，图不起")

        // 时钟开播：故意停着、有声音 —— 那一问当场把图起起来（等声卡），再从原处开播。
        check(try !audio.recoverIfNeeded(), "故意停着的图起回来不算「恢复」（时钟不用重新对画面）")
        check(audio.graphState == .running && audio.engine.isRunning, "有声音：开播前那一问回来时图已经在跑（不让播放头先空走一截）")
        check(!audio.feedersResting && audio.graphIsUp, "图起来了：喂样线程不歇了")
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

    // 后台起图没起来（没有能用的输出设备）：图还是故意停着的样子、喂样线程歇回去、只叫一次；时钟要出声时当场起、
    // 拿到真的错误；设备回来了照常起。2026-11-11 审查之前：状态成了「没在跑也不算停着」，喂样线程回到每 50 ms 轮询。
    do {
        struct NoDevice: Error {}
        let audio = try TimelineAudioEngine(config: AudioEngineConfig.make(from: plainLane(tone)), mode: .offline)
        defer { audio.stop() }
        check(try audio.recoverIfNeeded(), "前提：图起来了")
        audio.suspend()
        var failures = 0
        audio.onWakeFailed = { failures += 1 }
        audio.startGraph = { _ in throw NoDevice() }
        audio.wake()
        waitRunning(audio)
        pumpMain(until: { failures == 1 })
        check(failures == 1, "后台起图没起来：叫了一次（\(failures) 次）")
        check(audio.isSuspended && !audio.graphIsUp && !audio.engine.isRunning, "没起来：图还是故意停着的样子（状态 \(audio.graphState)）")
        check(audio.feedersResting, "没起来：喂样线程歇回去，不回到每 50 ms 轮询")
        var surfaced = false
        do { try audio.recoverIfNeeded() } catch { surfaced = error is NoDevice }
        check(surfaced, "时钟要出声：当场起、把真的错误报出来（时钟据此停播）")
        check(audio.isSuspended && audio.feedersResting, "当场起也没起来：还是故意停着、喂样线程歇着")
        audio.startGraph = { try $0.start() }
        check(try !audio.recoverIfNeeded(), "设备回来了：那一问照常把图起起来")
        check(audio.graphState == .running && audio.engine.isRunning && !audio.feedersResting, "设备回来了：图在跑")
        pumpMain(seconds: 0.05)
        check(failures == 1, "之后不再叫「没起来」")
    } catch {
        check(false, "后台起图没起来的回归失败：\(error)")
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

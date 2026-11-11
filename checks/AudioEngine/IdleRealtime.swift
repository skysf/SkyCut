import AVFoundation
import Foundation
import SrtFlowCore

// 第 15 组的第 4 层：真声卡上的空闲停图 / 再起（开发机跑 `scripts/check-audio-engine.sh --realtime-idle`，全程静音；
// CI 的虚拟机没有声卡，不在默认那一遍里）。前三层和这一组的来由见 Idle.swift。
//
// 验的是手动渲染验不了的那几样：停了之后原生图真的不跑；冷着按播放要等声卡起来、之后从原处开播、第一拍就是起点的声音；
// 用户先动一下（wake，后台起）之后按播放不用等；没有声音的时间线播着图也不起、播放头按 host 时间走；播着停图再起位置不跳；
// 停过再起总表的 tap 还在。

/// 10 秒的素材：`amplitude` 0 = 数字静音。自己写，不靠 ffmpeg。
func writeTone(_ url: URL, amplitude: Float, seconds: Double = 10) -> URL? {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frames = AVAudioFrameCount(seconds * 48_000)
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false   // 文件只能是交错的；不改的话 AVAudioFile 每次打一行日志
    guard let file = try? AVAudioFile(forWriting: url, settings: settings),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData else { return nil }
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        let sample = amplitude * sin(2 * Float.pi * 440 * Float(index) / 48_000)
        data[0][index] = sample
        data[1][index] = sample
    }
    do { try file.write(from: buffer) } catch { return nil }
    return url
}

func checkRealtimeEngineIdle() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-audioidle-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    guard let silence = writeTone(folder.appendingPathComponent("silence.wav"), amplitude: 0),
          let tone = writeTone(folder.appendingPathComponent("tone.wav"), amplitude: 0.5) else {
        return check(false, "造不出素材")
    }
    func lane(_ url: URL) -> AudioEngineConfig {
        var state = baseState()
        state.audioTracks = [EditLane(clips: [audioClip(url, duration: 10)])]
        return AudioEngineConfig.make(from: state)
    }

    do {
        let audio = try TimelineAudioEngine(config: lane(silence), mode: .realtime)
        defer { audio.stop() }
        audio.mute()
        try audio.start()
        audio.play(from: 1)
        Thread.sleep(forTimeInterval: 0.25)
        check(audio.playhead > 1.15, "前提：真声卡的时钟在走，实测 \(audio.playhead)")
        audio.pause()
        audio.suspend()
        check(audio.isSuspended && !audio.engine.isRunning, "真声卡：suspend 之后图不跑")
        Thread.sleep(forTimeInterval: 1.5)

        // 冷着按播放：和 PlayerClock.play 一样先问一次、紧跟着 play。那一问要等声卡起来（起声卡时整个进程本来就被拖住），
        // 之后从原处开播：播放头贴着「起点 + 从开播起过去的时间」走，第一拍就是起点的声音，不跳过。
        func seconds(since ticks: UInt64) -> Double {
            AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: ticks)
        }
        func watchStart(from start: Double, label: String) {
            let began = mach_absolute_time()
            var worst = 0.0
            var previous = audio.playhead
            var backwards = 0.0
            var firstBlockAt: Double?
            while seconds(since: began) < 0.5 {
                let elapsed = seconds(since: began)
                let now = audio.playhead
                if firstBlockAt == nil, audio.renderedHostTime != nil { firstBlockAt = now }
                worst = max(worst, abs(now - (start + elapsed)))
                backwards = max(backwards, previous - now)
                previous = now
                usleep(200)
            }
            check(firstBlockAt != nil, "\(label)：渲染块接上了")
            // 一拍约 11 ms：第一拍渲的就是起点，读到的位置离起点不到一拍多一点。
            check((firstBlockAt ?? 9) - start < 0.015, "\(label)：第一拍就是起点的声音，开头不跳过（第一拍在 \(firstBlockAt ?? -1)，起点 \(start)）")
            check(worst < 0.05, "\(label)：播放头贴着「起点 + 过去的时间」走，最多差 \(Int(worst * 1000)) ms")
            check(backwards < 0.001, "\(label)：播放头不往回走（最多回了 \(backwards * 1000) ms）")
        }
        let pressed = mach_absolute_time()
        check(try !audio.recoverIfNeeded(), "真声卡：故意停着的图起回来不算恢复")
        let waited = seconds(since: pressed)
        check(audio.graphState == .running && audio.engine.isRunning, "真声卡：开播前那一问回来时图已经在跑")
        audio.play(from: 5)
        print(String(format: "  冷着按播放：等声卡 %.0f ms", waited * 1000))
        watchStart(from: 5, label: "冷着开播")

        // 先动一下（wake，后台起）再按播放：wake 不等声卡；起好之后按播放和一直开着一样。
        audio.pause()
        audio.suspend()
        Thread.sleep(forTimeInterval: 1.5)
        let nudged = mach_absolute_time()
        audio.wake()
        check(seconds(since: nudged) < 0.03, "wake 不等声卡：\(Int(seconds(since: nudged) * 1000)) ms 就回来了")
        Thread.sleep(forTimeInterval: 0.6)
        check(audio.graphState == .running && audio.engine.isRunning, "真声卡：后台那一次起完，图在跑")
        let pressedAgain = mach_absolute_time()
        check(try !audio.recoverIfNeeded(), "真声卡：起好之后那一问什么都不做")
        audio.play(from: 7)
        check(seconds(since: pressedAgain) < 0.03, "先动过一下：按播放不用再等声卡（\(Int(seconds(since: pressedAgain) * 1000)) ms）")
        watchStart(from: 7, label: "先动一下再开播")
        // 每次开播头一两拍环里还没有数据是老样子（docs/architecture/audio-engine.md 第三节「已知」）；喂样线程要是没被叫醒，
        // 这三次各播的半秒会整段欠载（每次 24,000 帧）。
        check(audio.underrunFrames < 12_000, "停过再起：喂样线程醒了，环里有数据（三次开播一共欠了 \(audio.underrunFrames) 帧）")

        // 播着停图再起（配置从有声音变没有、又变回来）：位置连续。
        audio.suspend()
        let before = audio.playhead
        let suspendedAt = mach_absolute_time()
        Thread.sleep(forTimeInterval: 0.2)
        let slept = seconds(since: suspendedAt)
        let during = audio.playhead
        check(audio.isPlaying && !audio.engine.isRunning, "真声卡：播着停图，图不跑、还算在播")
        check(abs((during - before) - slept) < 0.03, "播着停图：播放头按 host 时间接着走（\(slept) 秒里走了 \(during - before)）")
        // 播着起回来：播放头一直按 host 时间在走，等声卡的那一截也算进去（图起来钉上时不跳、不往回走）。
        let asked = mach_absolute_time()
        check(try !audio.recoverIfNeeded(), "真声卡：播着每拍那一问把图起起来")
        Thread.sleep(forTimeInterval: 0.5)
        let after = audio.playhead
        check(audio.engine.isRunning && abs((after - during) - seconds(since: asked)) < 0.05,
              "播着停过再起：没跳（\(seconds(since: asked)) 秒里走了 \(after - during)）")
    } catch {
        check(false, "真声卡空闲回归失败：\(error)")
    }

    // 没有声音的时间线：播着图也不起，播放头按 host 时间走。
    do {
        let audio = try TimelineAudioEngine(config: .empty, mode: .realtime)
        defer { audio.stop() }
        audio.mute()
        try audio.start()
        audio.suspend()
        check(try !audio.recoverIfNeeded(), "真声卡 · 没有声音：开播前不起图")
        audio.play(from: 2)
        Thread.sleep(forTimeInterval: 0.3)
        check(try !audio.recoverIfNeeded(), "真声卡 · 没有声音：播着也不起图")
        check(!audio.engine.isRunning && audio.isSuspended, "真声卡 · 没有声音：播了 0.3 秒，图一直没开")
        check(abs(audio.playhead - 2.3) < 0.03, "真声卡 · 没有声音：播放头按 host 时间走到 2.3，实测 \(audio.playhead)")
        audio.pause()
        let stopped = audio.playhead
        Thread.sleep(forTimeInterval: 0.1)
        check(audio.playhead == stopped, "真声卡 · 没有声音：暂停之后播放头停住")
    } catch {
        check(false, "真声卡没有声音的回归失败：\(error)")
    }

    // 停过再起，总表的 tap 还在：总推子压到 −100 dB（听不见），表上还是量得到。
    do {
        var config = lane(tone)
        config.master = 0.000_01
        let meters = AudioMeterEngine()
        let audio = try TimelineAudioEngine(config: config, mode: .realtime, meters: meters)
        defer { audio.stop() }
        try audio.start()
        audio.suspend()
        check(try !audio.recoverIfNeeded(), "真声卡 · 电平表：起图")
        audio.play(from: 1)
        Thread.sleep(forTimeInterval: 0.6)
        let track = meters.slotPeak(for: .track(.lane(configTrackID(config)))) ?? (0, 0)
        let master = meters.slotPeak(for: .master) ?? (0, 0)
        check(max(track.left, track.right) > 0.3, "停过再起：轨道表量得到这条轨（峰值 \(track)）")
        check(max(master.left, master.right) > 0.000_001, "停过再起：总表的 tap 还在（峰值 \(master)）")
        audio.pause()
        audio.suspend()
        _ = meters.reading(for: .master, at: 1, now: 1)
        check((meters.slotPeak(for: .master) ?? (1, 1)) == (0, 0), "图停着读电平表：取走之后是零，不崩")
    } catch {
        check(false, "真声卡电平表回归失败：\(error)")
    }
}

/// 配置里那条音频轨的 id（电平表按它登记）。
private func configTrackID(_ config: AudioEngineConfig) -> UUID {
    if case let .track(.lane(id)) = config.tracks.first?.meterKey { return id }
    return UUID()
}

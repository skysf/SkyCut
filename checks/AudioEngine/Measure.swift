import AVFoundation
import CoreAudio
import Foundation
import SrtFlowCore

// 量「停过之后第一次播放多等多久」（开发机、真声卡、全程静音；不是断言，只打印数）：
//   scripts/check-audio-engine.sh --measure-idle [停多少秒=2] [几轮=10]
// 每一轮三种按法，都是 PlayerClock.play 对引擎做的那两句（recoverIfNeeded + play）：
//   一直开着：图在跑、停着，按播放；
//   冷着按：图故意停了 N 秒（声卡放手了），第一下就是按播放 —— 那两句里要等声卡起来；
//   先动一下：图停了 N 秒，用户先动了一下鼠标（wake，后台起图），0.25 秒之后按播放。
// 每次记五个数（毫秒，从按下起）：
//   那两句占主线程 —— 等声卡的时间就在这里（画面是这两句之后才按同一个 host 时刻钉的，所以它也是画面晚了多少）；
//   播放头开始走 —— 引擎的播放头第一次离开起点；
//   第一个有效渲染块 —— 渲染块第一次渲到这个锚点（墙上时间）；
//   声音出声卡 —— 那一拍的时间戳里写的出声时刻；
//   开头少了多少声音 —— 第一拍渲的位置比起点靠后多少（该是 0：等声卡起来再从原处放，不跳过）。
// 数字写进 docs/architecture/audio-engine.md 第二节第 11 条和 PR。

private func hostSeconds(_ ticks: UInt64) -> Double { AVAudioTime.seconds(forHostTime: ticks) }

private func outputDeviceIsRunning() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
    return running != 0
}

private struct Press {
    /// 那两句自己花了多久（主线程被占多久）。
    var call = 0.0
    var clock = 0.0
    var render = 0.0
    var sound = 0.0
    var skipped = 0.0
    /// 按下那一刻声卡是不是已经被别的程序开着（那样量到的不是冷启动）。
    var deviceBusy = false
}

/// 按一次播放，量到渲染块接上为止。
private func press(_ audio: TimelineAudioEngine, from start: Double) -> Press? {
    var result = Press()
    result.deviceBusy = outputDeviceIsRunning() && audio.graphState == .suspended
    let pressed = mach_absolute_time()
    do { try audio.recoverIfNeeded() } catch { print("起图失败：\(error)"); return nil }
    audio.play(from: start)
    result.call = (hostSeconds(mach_absolute_time()) - hostSeconds(pressed)) * 1000
    var clock: Double?
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while ProcessInfo.processInfo.systemUptime < deadline {
        let elapsed = (hostSeconds(mach_absolute_time()) - hostSeconds(pressed)) * 1000
        let playhead = audio.playhead
        if clock == nil, playhead > start + 0.000_5 { clock = elapsed }
        if let host = audio.renderedHostTime {
            result.render = elapsed
            result.sound = (hostSeconds(host) - hostSeconds(pressed)) * 1000
            // 这一拍渲的位置：播放头此刻的读数（一拍之内的 host 补偿只在出声时刻之后才加，这会儿还没到）。
            result.skipped = max(0, (playhead - start) * 1000)
            result.clock = clock ?? elapsed
            return result
        }
        usleep(50)
    }
    print("5 秒没等到渲染块")
    return nil
}

private func line(_ name: String, _ values: [Double]) -> String {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return "  \(name)：没有样本" }
    return String(format: "  %@：中位 %.1f / 最坏 %.1f / 最好 %.1f", name, sorted[sorted.count / 2], sorted.last!, sorted.first!)
}

private func report(_ title: String, _ presses: [Press]) {
    print("\(title)（\(presses.count) 次，其中声卡被别的程序开着 \(presses.filter(\.deviceBusy).count) 次）")
    print(line("那两句占主线程（画面晚多少）ms", presses.map(\.call)))
    print(line("播放头开始走 ms", presses.map(\.clock)))
    print(line("第一个有效渲染块 ms", presses.map(\.render)))
    print(line("声音出声卡 ms", presses.map(\.sound)))
    print(line("开头少了多少声音 ms", presses.map(\.skipped)))
}

func measureIdleWake(idle: Double, rounds: Int) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-audioidle-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    guard let silence = writeTone(folder.appendingPathComponent("silence.wav"), amplitude: 0, seconds: 30) else {
        print("造不出素材")
        return
    }
    var state = baseState()
    state.audioTracks = [EditLane(clips: [audioClip(silence, duration: 30)])]
    guard let audio = try? TimelineAudioEngine(config: AudioEngineConfig.make(from: state), mode: .realtime) else {
        print("引擎建不起来")
        return
    }
    defer { audio.stop() }
    audio.mute()
    do { try audio.start() } catch { print("真声卡起不来：\(error)"); return }
    Thread.sleep(forTimeInterval: 0.5)
    print("停 \(idle) 秒 × \(rounds) 轮；开跑之前声卡\(outputDeviceIsRunning() ? "在跑（含这个引擎自己）" : "没在跑")")

    var warm: [Press] = [], cold: [Press] = [], nudged: [Press] = []
    for round in 0..<rounds {
        // 一直开着
        audio.pause()
        Thread.sleep(forTimeInterval: 0.3 + Double.random(in: 0...0.02))
        if let result = press(audio, from: 3) { warm.append(result) }
        Thread.sleep(forTimeInterval: 0.2)
        // 冷着按
        audio.pause()
        audio.suspend()
        Thread.sleep(forTimeInterval: idle + Double.random(in: 0...0.02))
        if let result = press(audio, from: 3) { cold.append(result) }
        Thread.sleep(forTimeInterval: 0.2)
        // 先动一下
        audio.pause()
        audio.suspend()
        Thread.sleep(forTimeInterval: idle + Double.random(in: 0...0.02))
        audio.wake()
        Thread.sleep(forTimeInterval: 0.25)
        if let result = press(audio, from: 3) { nudged.append(result) }
        Thread.sleep(forTimeInterval: 0.2)
        FileHandle.standardError.write(Data("  第 \(round + 1) 轮完\n".utf8))
    }
    report("一直开着按播放", warm)
    report("冷着按播放（图停了 \(idle) 秒，第一下就是播放）", cold)
    report("先动一下、0.25 秒后按播放（图停了 \(idle) 秒）", nudged)
    print("欠载 \(audio.underrunFrames) 帧")
}

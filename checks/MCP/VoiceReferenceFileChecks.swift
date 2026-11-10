import AVFoundation
import Foundation

// 克隆参考录音 —— 真读真写这一半（SkyCut 声音方案 9.1 第 3 条）：现写几种素材，走生产的 VoiceReferenceSample.prepare
// （AVAssetReader → 挑段 → 44.1 kHz 单声道 16-bit WAV），再把写出来的文件按字节读回来（WAVHeader）：
// 44.1 kHz 16-bit 的源一个采样都不变；48 kHz 立体声超过 3 分钟挑在说话密的那里、不到 181 秒、取左右平均；
// 点名的一段原样截；AAC 的时间对得上；不到 10 秒的说差几秒、不留文件；取消也不留文件；贴着门限的样本按合同数（0.0056）；
// 再数一遍数的是写出去的 16-bit 采样；浮点源里的 NaN / ±Inf / 特别大的数不崩。纯值那一半在 VoiceReferenceChecks.swift。

func runVoiceReferenceFileChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-voice-reference-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await checkLosslessSource(root)
        let long = try await checkStereoPick(root)
        try await checkExplicitRange(long, root)
        try await checkTooLittleSpeech(root)
        try await checkContractFloor(root)
        try await checkRecountOnWrittenSamples(root)
        try await checkBadFloatSamples(root)
        try await checkCompressedTiming(root)
        await checkCancelled(long, root)
    } catch {
        check(false, "the voice reference file checks could not run: \(error)")
    }
}

/// 12 秒、44.1 kHz 单声道 16-bit，0.5–11.5 秒有声：整段用、11 秒人声、写出来的采样和源一模一样（没有偷偷降到 16 kHz）。
private func checkLosslessSource(_ root: URL) async throws {
    let rate = 44_100
    let samples = (0..<(12 * rate)).map { index -> Int16 in
        let time = Double(index) / Double(rate)
        return (0.5..<11.5).contains(time) ? VoiceReferenceSample.quantize(Float(0.2 * sin(2 * .pi * 220 * time))) : 0
    }
    let source = root.appendingPathComponent("lossless.wav")
    try VoiceReferenceSample.wavData(samples: samples, sampleRate: rate).write(to: source)
    let folder = root.appendingPathComponent("lossless")
    let sample = try await VoiceReferenceSample.prepare(from: source, folder: folder)
    check(!sample.autoSelected && sample.sourceStart == 0 && abs(sample.sourceEnd - 12) < 1e-9, "a 12 s recording is used whole: \(sample)")
    check(abs(sample.voicedSeconds - 11) < 1e-9, "11 s of speech, frame for frame: \(sample.voicedSeconds)")
    checkEqual(sample.url, folder.appendingPathComponent("reference.wav"), "the sample is written as reference.wav")
    let data = try Data(contentsOf: sample.url)
    check(data.count < 35_000_000, "the sample fits the 35 MB voice_reference upload")
    let header = WAVHeader(data)
    checkEqual(header?.isMono16BitPCM, true, "the sample is a mono 16-bit PCM WAV")
    checkEqual(header?.sampleRate, 44_100, "the sample is 44.1 kHz, not downsampled")
    check(header?.samples == samples, "a 44.1 kHz 16-bit source comes back sample for sample")
}

/// 4 分钟、48 kHz 立体声（只有左声道有声）：前 1 分钟稀、后 3 分钟密（最后一个字 239.6 秒说完）。自动挑在密的那 3 分钟：
/// 开口前 40 ms 起，停在最后的停顿里离最后一个字 40 ms（和读到尽头人声一样多，取短的）、不到 181 秒；
/// 混成单声道取平均（左 0.4、右 0 → 0.2）；报的人声秒数就是按写出来的采样数的。
private func checkStereoPick(_ root: URL) async throws -> URL {
    let source = root.appendingPathComponent("stereo-48k.wav")
    try writeAudio(source, seconds: 240, rate: 48_000, channels: 2) { channel, time in
        guard channel == 0 else { return 0 }
        let talking = time < 60 ? time.truncatingRemainder(dividingBy: 4) < 0.5 : (time - 60).truncatingRemainder(dividingBy: 2) < 1.6
        return talking ? Float(0.4 * sin(2 * .pi * 220 * time)) : 0
    }
    let sample = try await VoiceReferenceSample.prepare(from: source, folder: root.appendingPathComponent("stereo"))
    check(sample.autoSelected && sample.sourceStart >= 59.9 && sample.sourceStart <= 60 && abs(sample.sourceEnd - 239.64) < 0.03,
          "a 4-minute recording uses the dense last 3 minutes, from just before the first word to just after the last: \(sample)")
    check(sample.seconds < 181, "the sample stays under 181 s: \(sample.seconds)")
    check(abs(sample.voicedSeconds - 144) < 0.5, "90 bursts of 1.6 s are 144 s of speech: \(sample.voicedSeconds)")
    guard let header = WAVHeader(try Data(contentsOf: sample.url)) else { return source }
    check(header.isMono16BitPCM && header.sampleRate == 44_100, "a 48 kHz stereo source becomes a 44.1 kHz mono 16-bit sample")
    check(abs(header.samples.count - Int((sample.seconds * 44_100).rounded())) <= 1, "the reported range matches the written samples")
    let peak = Double(header.samples.map { abs(Int($0)) }.max() ?? 0) / 32_768
    check(abs(peak - 0.2) < 0.01, "stereo is mixed down to the average of left and right: peak \(peak)")
    check(abs(VoiceReferenceSample.voicedSeconds(of: header.samples) - sample.voicedSeconds) < 1e-9,
          "the reported speech is measured on the written samples")
    check(header.samples.prefix(1_764).allSatisfy { abs(Int($0)) < 200 }, "the sample starts in the pause, 40 ms before the first word")
    return source
}

/// 点名一段（100–150 秒）：不到 3 分钟，原样截那一段。
private func checkExplicitRange(_ source: URL, _ root: URL) async throws {
    let sample = try await VoiceReferenceSample.prepare(from: source, start: 100, end: 150, folder: root.appendingPathComponent("range"))
    check(!sample.autoSelected && abs(sample.sourceStart - 100) < 1e-9 && abs(sample.sourceEnd - 150) < 0.001,
          "a named range under 3 minutes is used as it is: \(sample)")
    let count = WAVHeader(try Data(contentsOf: sample.url))?.samples.count ?? 0
    check(abs(count - 2_205_000) <= 1, "50 s at 44.1 kHz: \(count) samples")
    checkEqual(sample.summary(name: source.lastPathComponent).hasPrefix("Voice sample: 1:40–2:30 of stereo-48k.wav"), true,
               "the summary names the range that was used")
}

/// 30 秒里只有 8 秒有声：拒绝，说还差 2 秒，理由和服务器的 too_little_speech 同名，不留文件。
private func checkTooLittleSpeech(_ root: URL) async throws {
    let rate = 44_100
    let samples = (0..<(30 * rate)).map { index -> Int16 in
        let time = Double(index) / Double(rate)
        return (5..<13).contains(time) ? VoiceReferenceSample.quantize(Float(0.2 * sin(2 * .pi * 220 * time))) : 0
    }
    let source = root.appendingPathComponent("short.wav")
    try VoiceReferenceSample.wavData(samples: samples, sampleRate: rate).write(to: source)
    let folder = root.appendingPathComponent("short")
    do {
        _ = try await VoiceReferenceSample.prepare(from: source, folder: folder)
        check(false, "8 s of speech must be refused")
    } catch let error as AIToolError {
        check(error.message.contains("8.0 s") && error.message.contains("2.0 s more"), "the refusal says how much is missing: \(error.message)")
        checkEqual(error.details["reason"], .string("too_little_speech"), "the reason matches the server's too_little_speech")
    } catch {
        check(false, "too little speech is a tool error, got \(error)")
    }
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference.wav").path), "a refused sample writes nothing")
}

/// AAC（有编码延迟、按包解码）：点名 20–50 秒，22 秒开口的声音落在样本的第 2 秒、40 秒的那一下落在第 20 秒。
private func checkCompressedTiming(_ root: URL) async throws {
    let source = root.appendingPathComponent("timing.m4a")
    try writeAudio(source, seconds: 60, rate: 44_100, channels: 1, aac: true) { _, time in
        (22..<34).contains(time) || (40..<40.5).contains(time) ? Float(0.3 * sin(2 * .pi * 220 * time)) : 0
    }
    let sample = try await VoiceReferenceSample.prepare(from: source, start: 20, end: 50, folder: root.appendingPathComponent("aac"))
    let samples = WAVHeader(try Data(contentsOf: sample.url))?.samples ?? []
    check(abs(samples.count - 1_323_000) <= 2, "a 30 s range of AAC is 30 s of samples: \(samples.count)")
    func onset(after seconds: Double) -> Double {
        let first = Int(seconds * 44_100)
        guard first < samples.count, let index = samples[first...].firstIndex(where: { abs(Int($0)) > 6_554 }) else { return -1 }
        return Double(index) / 44_100
    }
    check(abs(onset(after: 0) - 2) < 0.015, "speech at 22 s in the file starts 2 s into the sample: \(onset(after: 0))")
    check(abs(onset(after: 15) - 20) < 0.015, "the burst at 40 s lands at 20 s; AAC priming does not shift it: \(onset(after: 15))")
    check(abs(sample.voicedSeconds - 12.5) < 0.2, "12.5 s of speech in the range: \(sample.voicedSeconds)")
}

/// 门限的合同（RMS ≥ 0.0056，服务器放宽到 0.0055）：9.9 秒的声音 + 5 格正好贴着门限的声音（±184，RMS 0.0056152 ≈ −45.01 dBFS）
/// = 正好 10.0 秒有效人声，收。按精确的 −45 dBFS（0.0056234）数就只剩 9.9 秒、被拒 —— 审查的 borderline.wav 就是这个形状
/// （docs/bugfixes/2026-11-10-voice-reference-floor-borrowed-from-voice-level.md）。
private func checkContractFloor(_ root: URL) async throws {
    let rate = 44_100
    var samples = (0..<(495 * 882)).map { VoiceReferenceSample.quantize(Float(0.2 * sin(2 * .pi * 220 * Double($0) / Double(rate)))) }
    samples += [Int16](repeating: 0, count: 25 * 882)
    samples += (0..<(5 * 882)).map { $0 % 2 == 0 ? 184 : -184 }
    samples += [Int16](repeating: 0, count: 50 * 882)
    let source = root.appendingPathComponent("borderline.wav")
    try VoiceReferenceSample.wavData(samples: samples, sampleRate: rate).write(to: source)
    do {
        let sample = try await VoiceReferenceSample.prepare(from: source, folder: root.appendingPathComponent("borderline"))
        check(abs(sample.voicedSeconds - 10) < 1e-9 && !sample.autoSelected,
              "frames at RMS 0.0056152 count as speech: exactly 10.0 s, accepted: \(sample.voicedSeconds)")
    } catch {
        check(false, "a sample right at the contract floor (10.0 s at RMS ≥ 0.0056) must be accepted: \(error)")
    }
}

/// 再数一遍数的是要上传的 16-bit 采样：浮点源里 10 格的均方根刚好高过门限（九成 ±183.49、一成 ±184.49，RMS 0.0056028），
/// 量化成 ±183 / ±184 之后只剩 0.0055878。挑段时按浮点算 10.1 秒，写出去的只有 9.9 秒：拒，按写出去的说差多少。
private func checkRecountOnWrittenSamples(_ root: URL) async throws {
    let source = root.appendingPathComponent("borderline-float.wav")
    try writeAudio(source, seconds: 11.1, rate: 44_100, channels: 1, float: true) { _, time in
        let index = Int((time * 44_100).rounded())
        if index < 495 * 882 { return Float(0.2 * sin(2 * .pi * 220 * time)) }
        guard index < 505 * 882 else { return 0 }
        let units: Float = index % 882 % 10 == 0 ? 184.49 : 183.49
        return (index % 2 == 0 ? 1 : -1) * units / 32_768
    }
    do {
        _ = try await VoiceReferenceSample.prepare(from: source, folder: root.appendingPathComponent("borderline-float"))
        check(false, "speech counted on Float but not on the written 16-bit samples must be refused")
    } catch let error as AIToolError {
        check(error.message.contains("9.9 s") && error.details["voiced_seconds"]?.doubleValue == 9.9,
              "the refusal counts the written 16-bit samples (9.9 s), not the Float scan (10.1 s): \(error.message)")
    } catch {
        check(false, "a recount shortfall is a tool error, got \(error)")
    }
}

/// 浮点源里的坏采样（NaN、±Inf、1e20）：以前整个 App 崩掉；现在坏的记成 0、特别大的夹到满幅，其余照常
/// （docs/bugfixes/2026-11-10-voice-reference-nan-sample-crash.md）。
private func checkBadFloatSamples(_ root: URL) async throws {
    let bad: [Int: Float] = [5 * 44_100: .nan, 6 * 44_100: .infinity, 7 * 44_100: -.infinity, 8 * 44_100: 1e20, 9 * 44_100: -1e20]
    let source = root.appendingPathComponent("bad-samples.wav")
    try writeAudio(source, seconds: 15, rate: 44_100, channels: 1, float: true) { _, time in
        bad[Int((time * 44_100).rounded())] ?? Float(0.2 * sin(2 * .pi * 220 * time))
    }
    let sample = try await VoiceReferenceSample.prepare(from: source, folder: root.appendingPathComponent("bad"))
    let samples = WAVHeader(try Data(contentsOf: sample.url))?.samples ?? []
    checkEqual(bad.keys.sorted().map { $0 < samples.count ? samples[$0] : 1 }, [0, 0, 0, 32_767, -32_768],
               "NaN and ±infinity are written as silence, 1e20 clamps to full scale")
    check(abs(sample.voicedSeconds - 15) < 1e-9, "the rest of the recording is untouched: \(sample.voicedSeconds) s of speech")
}

/// 取消：读取线程上停下，不写文件。
private func checkCancelled(_ source: URL, _ root: URL) async {
    let folder = root.appendingPathComponent("cancelled")
    let task = Task { try await VoiceReferenceSample.prepare(from: source, folder: folder) }
    task.cancel()
    if case .success = await task.result { check(false, "a cancelled sample must not finish") }
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference.wav").path), "a cancelled sample writes nothing")
}

/// 现写一段 16-bit PCM（`float` 是 32 位浮点、原样写进去，NaN 也照写；或 AAC）素材：每个声道每个时刻的值由 `signal` 给。
private func writeAudio(_ url: URL, seconds: Double, rate: Double, channels: Int, aac: Bool = false, float: Bool = false,
                        signal: (Int, Double) -> Float) throws {
    var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
    if aac {
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVEncoderBitRateKey] = 128_000
    } else {
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = float ? 32 : 16
        settings[AVLinearPCMIsFloatKey] = float
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let total = Int(seconds * rate)
    var written = 0
    while written < total {
        let count = min(Int(rate), total - written)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { throw AIToolError("could not allocate a test buffer") }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            for index in 0..<count { data[channel][index] = signal(channel, Double(written + index) / rate) }
        }
        try file.write(from: buffer)
        written += count
    }
}

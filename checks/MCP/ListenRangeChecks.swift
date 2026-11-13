import AVFoundation
import Foundation
import SrtFlowMCPKit

// 文件 listen 的真实生产路径回归：本机现造稀疏长 WAV，仅写晚时间点的三秒声音；不使用用户媒体。
// 暂停测试进程的 overview 队列，文件生产入口仍必须成功，避免悄悄落回整文件 WaveformStore。
// **要证明的事一律数出来，不量快慢**（2026-11-13，docs/bugfixes/2026-11-13-listen-range-checks-timed-out-under-load.md）：
// 被测的那一次文件 listen 里起了几个 reader、各自的 timeRange、原生一共交出多少帧、要没要整文件波形、起没起节拍的读取
//（ListenReadTally.swift：账绑在这一次调用上，登记点在「要」的那一刻同步记），回来的是结果还是超时 / 取消。传给生产入口的截止时间
// 只为卡死时有个头（listenCheckHangBound）；超时、取消怎么结束在 ListenReadEndChecks.swift，判的是「回来的是什么」，不是「几秒内回来」。

/// 这一组每次读的都是几十毫秒的活。传给生产入口的截止时间只拦卡死，和真工具的 `AIListenTool.waitSeconds` 一样是 40 秒
///（那个类型不在这个自检的编译清单里）。2026-11-13 之前是 2 秒：机器满载时读三秒音频也等不到它，这一组就红。
let listenCheckHangBound: TimeInterval = 40
/// 整组的看门狗：只防有谁的 await 永远不回来（截止时间都没管住的那种卡死），不量整组多快。
private let listenSuiteHangBound: TimeInterval = 300

@MainActor
func runListenRangeChecks() async {
    let watchdog = DispatchWorkItem {
        FileHandle.standardError.write(Data("✗ listen range production checks did not finish in \(Int(listenSuiteHangBound)) seconds\n".utf8))
        exit(1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + listenSuiteHangBound, execute: watchdog)
    defer { watchdog.cancel() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow-ListenRange-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeListenRangeFixture(in: directory)
        await checkListenFileRange(url)
        await checkNativeListenRange(url)
        await runListenReaderLifecycleChecks(url)
        await checkListenReadEnds(url)
        await checkListenMusicLimit(url)
        await checkListenShortFile(in: directory)
        await checkCompressedListenRange(in: directory)
        await checkListenEditCoverage(in: directory)
    } catch {
        check(false, "listen range fixture/production path failed: \(error)")
    }
}

let listenRangeStart = 3_200.125
private let listenFixtureRate = 48_000.0

/// RIFF PCM16：一小时、双声道，未写的部分为文件系统稀疏洞（0），实际只写 3.2 秒，不整片编码/拷贝。
private func makeListenRangeFixture(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("synthetic-hour.wav")
    let frames = UInt32(listenFixtureRate * 3_600)
    let bytes = frames * 4
    var header = Data()
    func word<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
    }
    header.append(Data("RIFF".utf8)); word(bytes + 36); header.append(Data("WAVEfmt ".utf8))
    word(UInt32(16)); word(UInt16(1)); word(UInt16(2)); word(UInt32(listenFixtureRate))
    word(UInt32(listenFixtureRate * 4)); word(UInt16(4)); word(UInt16(16))
    header.append(Data("data".utf8)); word(bytes)
    _ = FileManager.default.createFile(atPath: url.path, contents: header)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.truncate(atOffset: UInt64(44 + bytes))
    let first = Int((listenRangeStart - 0.1) * listenFixtureRate)
    let last = Int((listenRangeStart + 3.1) * listenFixtureRate)
    var samples: [Int16] = []
    for frame in first..<last {
        let time = Double(frame) / listenFixtureRate - listenRangeStart
        let amplitude: Double
        if time < 0 || time >= 3 { amplitude = 0.95 } // 窗外尖峰不能混进请求结果。
        else if time < 1 { amplitude = 0.5 }
        else if time < 2 { amplitude = 0 }
        else { amplitude = 0.1 }
        let sample = amplitude * sin(2 * .pi * 440 * Double(frame) / listenFixtureRate)
        samples.append(Int16((sample * 32767).rounded()).littleEndian)
        samples.append(Int16((sample * 0.5 * 32767).rounded()).littleEndian)
    }
    try file.seek(toOffset: UInt64(44 + first * 4))
    try samples.withUnsafeBytes { try file.write(contentsOf: $0) }
    return url
}

@MainActor
private func checkListenFileRange(_ url: URL) async {
    MediaReadQueue.overview.isSuspended = true
    defer { MediaReadQueue.overview.cancelAllOperations(); MediaReadQueue.overview.isSuspended = false }
    do {
        let result = try await boundedFileListen(url, sourceIn: listenRangeStart, sourceOut: listenRangeStart + 3,
                                                 reads: listenRangeStart, listenRangeStart + 3, "late range")
        checkEqual(result["from"]?.doubleValue, listenRangeStart, "late file range starts at the requested source second")
        checkEqual(result["to"]?.doubleValue, listenRangeStart + 3, "late file range completes without a whole-file overview")
        check(abs((result["peak_db"]?.doubleValue ?? 0) + 6) < 0.1, "window excludes louder samples just outside its bounds")
        check(abs((result["level_db"]?.doubleValue ?? 0) + 13.9) < 0.5, "stereo RMS excludes the silent second")
        checkEqual(result["silences"]?.arrayValue?.count, 1, "the source window contains one silence")
        if let silence = result["silences"]?.arrayValue?.first?.arrayValue,
           let first = silence.first?.doubleValue, let last = silence.last?.doubleValue {
            check(abs(first - listenRangeStart - 1) < 0.05 && abs(last - listenRangeStart - 2) < 0.05,
                  "silence timestamps stay in the late source range")
        } else { check(false, "missing source-window silence timestamps") }
        check(result["note"] == nil, "an explicit window returns a complete report, never a partial waveform snapshot")
        let tail = try await boundedFileListen(url, sourceIn: 3_599, sourceOut: nil, reads: 3_599, 3_600, "source_in alone")
        checkEqual(tail["to"]?.doubleValue, 3_600, "source_in alone ends at reliable container duration")
        let head = try await boundedFileListen(url, sourceIn: nil, sourceOut: 0.2, reads: 0, 0.2, "source_out alone")
        checkEqual(head["from"]?.doubleValue, 0, "source_out alone starts at the file origin")
    } catch { check(false, "bounded file listen must work with overview suspended: \(error)") }
}

/// 一次带区间的文件 listen，数的是**这一次调用**里要过的读取（ListenReadTally）：恰好一个有界 reader、它自己的 timeRange 就是 [from, to]、
/// 这次调用起的 reader 原生一共交出的帧数不超过这一窗；一次都没要整文件波形（登记在 WaveformStore 收到请求的那一刻，不等它往 overview 上排活），
/// 没起节拍的读取。多出来的读取一登记，这次调用当场被停掉、判红：不等截止时间，也不看它多快回来。
@MainActor
private func boundedFileListen(
    _ url: URL, sourceIn: Double?, sourceOut: Double?, beats: Bool = false, reads from: Double, _ to: Double, _ label: String
) async throws -> [String: JSONValue] {
    let (result, tally) = await talliedFileListen(url, sourceIn: sourceIn, sourceOut: sourceOut, beats: beats,
                                                  plan: .window(from: from, to: to))
    check(tally.readsOnly(from: from, to: to),
          "\(label): this file listen starts exactly one native reader, limited to the requested range (started \(tally.windows))")
    // 下限：生产的覆盖校验两头各容两帧；上限同 checkNativeListenRange（PCM 一包 8,192 帧）。
    let frames = Int(((to - from) * listenFixtureRate).rounded())
    check(tally.finishedWindows == tally.windows.count && tally.decodedFrames >= frames - 4 && tally.decodedFrames <= frames + 8_192,
          "\(label): the readers this call started decode the requested range and no more, in total (\(tally.decodedFrames) frames from \(tally.finishedWindows) readers)")
    check(tally.decodedFrom >= from - 0.1 && tally.decodedTo <= to + 0.1,
          "\(label): decoded samples stay around the requested range (got \(tally.decodedFrom)–\(tally.decodedTo))")
    checkEqual(tally.wholeFileRequests, 0, "\(label): an explicit file range never asks WaveformStore for the whole-file waveform")
    checkEqual(tally.beatReads, 0, "\(label): no beat decode is started")
    return try result.get()
}

@MainActor
private func checkNativeListenRange(_ url: URL) async {
    do {
        let reading = try await AIListenAudioWindow.read(url, from: listenRangeStart, to: listenRangeStart + 3,
                                                       until: Date().addingTimeInterval(listenCheckHangBound))
        checkEqual(reading.fileDuration, 3_600, "duration comes from the container, not decoded coverage")
        checkEqual(reading.peaks.channelCount, 2, "bounded decoder preserves stereo")
        checkEqual(reading.peaks.sampleRate, listenFixtureRate, "bounded decoder keeps the native sample rate")
        check(reading.decodedFrames <= Int(3 * listenFixtureRate) + 8_192,
              "reader.timeRange bounds actual decoded sample count (got \(reading.decodedFrames))")
        check(reading.decodedFrom >= listenRangeStart - 0.1 && reading.decodedTo <= listenRangeStart + 3.1,
              "native reader samples stay around the requested late range")
        checkEqual(reading.peaks.framesAvailable, Int(3 * listenFixtureRate), "only three seconds enter peak/power buckets")
        check(abs((reading.windows.last?.end ?? 0) - listenRangeStart - 3) < 1 / listenFixtureRate,
              "the last reported window ends at the requested source out")
        do {
            _ = try await AIListenAudioWindow.read(url, from: 3_601, to: 3_602, until: Date().addingTimeInterval(listenCheckHangBound))
            check(false, "out-of-container range must fail")
        } catch let error as AIToolError {
            check(error.message.contains("3600.00") && !error.message.contains("s read"), "range errors use real file duration")
        }
    } catch { check(false, "native bounded audio reading failed: \(error)") }
}

@MainActor
private func checkListenMusicLimit(_ url: URL) async {
    do {
        let result = try await boundedFileListen(url, sourceIn: listenRangeStart, sourceOut: listenRangeStart + 0.1, beats: true,
                                                 reads: listenRangeStart, listenRangeStart + 0.1, "long-file beats")
        check(result["beats"]?.stringValue?.contains("15-minute") == true, "long-file beats return the existing music limit")
        check(result["beat_note"]?.stringValue?.contains("No beat decoding was started") == true, "long-file beat decode is skipped explicitly")
    } catch { check(false, "long-file beat limit failed: \(error)") }
}

@MainActor
private func checkListenShortFile(in directory: URL) async {
    do {
        let url = directory.appendingPathComponent("short-silent.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: listenFixtureRate, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 48_000)
        try file?.write(from: buffer)
        file = nil
        let (outcome, tally) = await talliedFileListen(url, sourceIn: nil, sourceOut: nil, beats: true, plan: .wholeFile(beats: true))
        // 登记点是活的：上面那些「一次都没要整文件波形 / 没起节拍的读取」不是因为没人记 —— 没给区间的 listen 就该看得见这两样。
        check(tally.wholeFileRequests == 1 && tally.wholeFileDecodes == 1,
              "a whole-file listen is seen asking WaveformStore once for a new whole-file decode (saw \(tally.wholeFileRequests) requests, \(tally.wholeFileDecodes) new decodes)")
        checkEqual(tally.beatReads, 1, "short-file beats are seen starting their own read")
        checkEqual(tally.windows.count, 0, "a whole-file listen starts no bounded range reader")
        let result = try outcome.get()
        checkEqual(result["level_db"]?.stringValue, "silent", "normal short-file shared-waveform listen remains compatible")
        check(result["beat_note"]?.stringValue?.contains("whole-song") == true, "short-file beat result explains its independent analysis window")
    } catch { check(false, "short-file listen compatibility failed: \(error)") }
}

@MainActor
private func checkCompressedListenRange(in directory: URL) async {
    do {
        let url = directory.appendingPathComponent("synthetic-tone.m4a")
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: listenFixtureRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        let format = file!.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(0.25 * sin(2 * .pi * 440 * Double(index) / listenFixtureRate)) }
        try file?.write(from: buffer)
        file = nil
        let from = 0.12371, to = 0.45679
        let reading = try await AIListenAudioWindow.read(url, from: from, to: to, until: Date().addingTimeInterval(listenCheckHangBound))
        check(reading.sourceStart >= from - 1 / listenFixtureRate, "AAC package preroll is excluded from statistical buckets")
        check(abs((reading.windows.last?.end ?? 0) - to) <= 2 / listenFixtureRate, "AAC range ends within two native samples")
        check(reading.peaks.framesAvailable <= Int(ceil((to - from) * listenFixtureRate)) + 1, "AAC statistics contain only the requested source span")
        check(reading.decodedFrames <= Int((to - from + 0.1) * listenFixtureRate), "AAC native reading stays bounded to the short window")
    } catch { check(false, "compressed source-window reading failed: \(error)") }
}

@MainActor
private func checkListenEditCoverage(in directory: URL) async {
    do {
        let tone = AVURLAsset(url: directory.appendingPathComponent("synthetic-tone.m4a"))
        let source = try await tone.loadTracks(withMediaType: .audio)[0]
        let second = CMTime(value: 1, timescale: 1)
        let one = CMTimeRange(start: .zero, duration: second)
        let gap = AVMutableComposition()
        let audio = gap.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try audio.insertTimeRange(one, of: source, at: .zero)
        audio.insertEmptyTimeRange(CMTimeRange(start: second, duration: second))
        try audio.insertTimeRange(one, of: source, at: second + second)
        let gapURL = directory.appendingPathComponent("synthetic-gap.mov")
        let gapExport = AVAssetExportSession(asset: gap, presetName: AVAssetExportPresetPassthrough)!
        try await gapExport.export(to: gapURL, as: .mov)
        await checkCoverageOrRefusal(gapURL, from: 0, to: 3, gap: true)

        let videoURL = directory.appendingPathComponent("synthetic-picture.mp4")
        guard await writeTinyH264(to: videoURL, frameCount: 30) else {
            check(false, "could not make native video for offset-audio coverage")
            return
        }
        let video = AVURLAsset(url: videoURL)
        let picture = try await video.loadTracks(withMediaType: .video)[0]
        let offset = AVMutableComposition()
        try offset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: try await video.load(.duration)), of: picture, at: .zero)
        try offset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(one, of: source, at: second)
        let offsetURL = directory.appendingPathComponent("synthetic-offset.mov")
        let offsetExport = AVAssetExportSession(asset: offset, presetName: AVAssetExportPresetPassthrough)!
        try await offsetExport.export(to: offsetURL, as: .mov)
        await checkCoverageOrRefusal(offsetURL, from: 0.25, to: 1.5, gap: false)
        await checkCoverageOrRefusal(offsetURL, from: 1.5, to: 2.75, gap: false)
    } catch { check(false, "native edit-list coverage fixture failed: \(error)") }
}

@MainActor
private func checkCoverageOrRefusal(_ url: URL, from: Double, to: Double, gap: Bool) async {
    do {
        let reading = try await AIListenAudioWindow.read(url, from: from, to: to, until: Date().addingTimeInterval(listenCheckHangBound))
        // 某些解码器会原生填零；那就必须确实覆盖全窗，不能把不连续的 PTS 压成连续时间。
        check(abs(reading.sourceStart - from) < 0.001 && abs((reading.windows.last?.end ?? 0) - to) < 0.001,
              "a completed edit-list report covers its full requested range: \(url.lastPathComponent) \(from)–\(to)")
        if gap {
            let report = AIAudioLevels.report(reading.windows, silenceDB: -45, minSilence: 0.5)
            check(report.silences.contains { abs($0.lowerBound - 1) < 0.1 && abs($0.upperBound - 2) < 0.1 },
                  "native-filled edit-list gap keeps the silence at source 1–2 seconds")
        }
    } catch let error as AIToolError {
        check(error.message.contains("coverage") || error.message.contains("audio samples"),
              "uncovered/discontinuous source audio is explicitly refused: \(error.message)")
    } catch { check(false, "unexpected edit-list range error: \(error)") }
}

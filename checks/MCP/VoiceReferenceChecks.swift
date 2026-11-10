import Foundation

// 克隆参考录音（SkyCut 声音方案第六节、9.1 第 3 条）—— 纯值这一半：
// VoiceReferenceWindow 的有声门限（和 Sky Studio 的合同：RMS ≥ 0.0056）、10 秒下限、3 分钟上限（正好 3 分钟还是整段）、
// 挑有效人声最多的一段、一样多比前 15 秒再比早、切口只在 ≥ 0.2 秒的停顿里且离两头 40 ms、尽头也能当终点、一直有声时退到
// 最安静的格子边，并和一个照规矩直写的穷举对账（choose 里的二分和剪枝）；边读边算的响度和一口气算的一样；
// WAV 的头（44.1 kHz 单声道 16-bit）、量化（坏采样 NaN / ±Inf 记 0、特别大的夹住，不许崩）、写给 AI 的那一句、上传用途。
// 真读真写（AVFoundation → 挑段 → WAV → 读回来）在 VoiceReferenceFileChecks.swift。规矩见 docs/architecture/voice-library.md。

private typealias Window = VoiceReferenceWindow
private let loud: Float = 0.1

/// 按秒拼一串 20 ms 的格：(秒, 有没有声)。
private func frames(_ parts: [(Double, Bool)]) -> [Float] {
    parts.flatMap { seconds, voiced in [Float](repeating: voiced ? loud : 0, count: Int((seconds / Window.frameSeconds).rounded())) }
}

private func cycles(_ count: Int, _ cycle: [(Double, Bool)]) -> [(Double, Bool)] { (0..<count).flatMap { _ in cycle } }

private func seconds(_ levels: [Float]) -> Double { Double(levels.count) * Window.frameSeconds }

private func checkClose(_ actual: Double, _ expected: Double, _ message: String, line: Int = #line) {
    check(abs(actual - expected) < 1e-6, "\(message): got \(actual), expected \(expected)", line: line)
}

func runVoiceReferenceChecks() {
    checkEqual(Window.minimumVoicedSeconds, 10, "a voice sample needs at least 10 s of clear speech (MiniMax's hard minimum)")
    checkEqual(Window.maximumSeconds, 180, "a voice sample is at most 3 minutes")
    // 有声门限是和 Sky Studio 的合同：SkyCut RMS ≥ 0.0056（≈ −45.04 dBFS），服务器故意放宽到 0.0055，只会更宽不会更严。
    checkEqual(Window.speechRMSFloor, 0.0056, "the speech floor is the contract with Sky Studio: frame RMS ≥ 0.0056 (the server relaxes to 0.0055)")
    checkEqual(Window.voicedFrames(levels: [0.0056, Float(0.0056).nextDown, 0.0056234, 0.0055]), 2,
               "0.0056 and exact −45 dBFS count as speech; just below 0.0056 and the server's 0.0055 do not")
    runWholeAndMinimumChecks()
    runPickChecks()
    runOracleChecks()
    runMeterChecks()
    runSampleFormatChecks()
}

private func runWholeAndMinimumChecks() {
    let whole = Window.choose(levels: frames([(2, false), (12, true), (16, false)]), duration: 30.013)
    checkEqual(whole, Window(start: 0, end: 30.013, voicedFrames: 600, autoSelected: false),
               "under 3 minutes the whole recording is the sample, tail included")
    check(whole.hasEnoughSpeech && abs(whole.voicedSeconds - 12) < 1e-9, "12 s of speech is enough")
    let exactly = Window.choose(levels: frames([(10, true), (5, false)]), duration: 15)
    check(exactly.hasEnoughSpeech && exactly.voicedFrames == 500, "exactly 10 s (500 frames) of speech is enough")
    let almost = Window.choose(levels: frames([(9.98, true), (5, false)]), duration: 15)
    check(!almost.hasEnoughSpeech && almost.voicedFrames == 499, "9.98 s of speech is not enough")
    // 正好 3 分钟、结尾有 0.5 秒静音：还是整段（`>` 不是 `>=`：走了挑段就会切在结尾的停顿里、变成 179.54 秒）。
    let threeMinutes = Window.choose(levels: frames([(179.5, true), (0.5, false)]), duration: 180)
    check(!threeMinutes.autoSelected && threeMinutes.start == 0 && threeMinutes.end == 180,
          "exactly 3 minutes is still the whole recording, trailing pause included: \(threeMinutes)")
    checkEqual(Window.voicedFrames(levels: [Window.speechRMSFloor, Window.speechRMSFloor.nextDown, 0, 1]), 2,
               "the floor itself counts as speech, just below it does not")
    checkEqual(Window.pauseRuns(frames([(0.3, false), (1, true), (0.18, false), (1, true), (0.2, false)])), [0..<15, 124..<134],
               "pauses are runs of at least 0.2 s below the floor, at the edges too; 0.18 s is not a pause")
}

private func runPickChecks() {
    // 前 2 分钟稀（1 秒声 4 秒停），后 5 分钟密（4 秒声 0.5 秒停）：用的那一段落在密的那里，两头切在停顿里。
    let mixed = frames(cycles(24, [(1, true), (4, false)]) + cycles(67, [(4, true), (0.5, false)]))
    let picked = Window.choose(levels: mixed, duration: seconds(mixed))
    check(picked.autoSelected && picked.start >= 120 - 0.05, "the sample starts in the dense part: \(picked)")
    check(picked.seconds >= 179 - 1e-9 && picked.seconds < 181, "the sample ends within a second of 3:00 and stays under 181 s: \(picked.seconds)")
    checkCuts(picked, in: mixed, "dense part")

    // 两段一样多的话：前 15 秒更密的那段赢；再一样，早的赢。
    let first = [(0.04, false)] + cycles(85, [(1, true), (1, false)])
    let frontLoaded = [(15.0, true), (1.0, false)] + cycles(70, [(1, true), (1, false)])
    let leading = frames(first + [(230, false)] + frontLoaded + [(244, false)])
    let lead = Window.choose(levels: leading, duration: seconds(leading))
    checkEqual(lead.voicedFrames, 4_250, "both blocks hold 85 s of speech")
    checkClose(lead.start, 400, "equal speech: the block with the denser first 15 s wins")
    checkClose(lead.end, 579, "its end is the first cut 179 s later, inside the silence")
    let twins = frames(first + [(230, false)] + first.dropFirst() + [(244, false)])
    let twin = Window.choose(levels: twins, duration: seconds(twins))
    checkClose(twin.start, 0, "equal speech and equal first 15 s: the earliest block wins")
    checkEqual(twin.voicedFrames, 4_250, "the earliest block keeps all its speech")

    // 一直有声、没有停顿：退到 3:00 前后 1 秒里最安静的格子边（都一样就取最早的 179 秒）。
    var solid = frames([(300, true)])
    let flat = Window.choose(levels: solid, duration: 300)
    check(flat.autoSelected && flat.start == 0, "no pause anywhere: the sample starts at the beginning")
    checkClose(flat.end, 179, "no pause anywhere and all frames equal: cut at the earliest edge (179 s)")
    solid[9_020] = 0.05
    checkClose(Window.choose(levels: solid, duration: 300).end, 180.4, "no pause anywhere: cut at the edge next to the quietest frame")

    // 0.18 秒的小停顿不能切；3:00 附近只有一个 0.24 秒的真停顿，终点就落在它里面、离开头 40 ms
    //（它后面 0.56 秒还有一个 0.18 秒的小停顿：小停顿要是也能切，终点就会挪到那里，多装 0.56 秒的声音）。
    let choppy = frames(cycles(89, [(1.82, true), (0.18, false)]) + [(2, true), (0.24, false), (0.56, true), (0.18, false)]
                        + cycles(110, [(1.82, true), (0.18, false)]))
    let gap = Window.choose(levels: choppy, duration: seconds(choppy))
    checkClose(gap.start, 0, "short gaps are not start points")
    checkClose(gap.end, 180.04, "the end sits 40 ms into the only real pause near 3:00")

    // 前 100 秒没声：从开口前 40 ms 一直用到结尾（够得着就停在尽头，真实的时长、带不满一格的尾巴）。
    let late = frames([(100, false)] + cycles(20, [(4.5, true), (0.5, false)]))
    let tail = Window.choose(levels: late, duration: 200.013)
    checkClose(tail.start, 99.96, "a late start begins 40 ms before the first word")
    check(tail.end == 200.013 && tail.voicedFrames == 4_500 && tail.autoSelected,
          "a late start runs to the true end of the recording and keeps all the speech: \(tail)")
}

/// 起点：开头，或一个 ≥ 0.2 秒停顿之后的开口前 40 ms；终点：尽头，或停顿里离两头至少 40 ms。
private func checkCuts(_ window: Window, in levels: [Float], _ label: String) {
    let silent = { (frame: Int) in frame >= 0 && frame < levels.count && levels[frame] < Window.speechRMSFloor }
    func run(around frame: Int) -> Int {
        var low = frame, high = frame
        while silent(low - 1) { low -= 1 }
        while silent(high + 1) { high += 1 }
        return high - low + 1
    }
    let start = Int((window.start / Window.frameSeconds).rounded())
    if start > 0 {
        check(silent(start) && silent(start + 1) && !silent(start + 2) && run(around: start) >= 10,
              "\(label): the start is 40 ms before an onset that follows a pause of at least 0.2 s")
    }
    let end = Int((window.end / Window.frameSeconds).rounded())
    if end < levels.count {
        check((end - 2...end + 1).allSatisfy(silent) && run(around: end) >= 10,
              "\(label): the end is at least 40 ms inside a pause of at least 0.2 s")
    }
}

// MARK: 和穷举对账

private func runOracleChecks() {
    for seed in UInt64(1)...16 {
        let levels = randomLevels(seed: seed)
        let duration = seconds(levels) + 0.013
        let window = Window.choose(levels: levels, duration: duration)
        let expected = bruteForce(levels, duration: duration)
        let start = Int((window.start / Window.frameSeconds).rounded())
        let end: Int? = window.end == duration ? nil : Int((window.end / Window.frameSeconds).rounded())
        check(start == expected.start && end == expected.end && window.voicedFrames == expected.voiced,
              "seed \(seed): choose picked \(start)..<\(end.map(String.init) ?? "end") (\(window.voicedFrames) voiced), "
                + "the exhaustive search \(expected.start)..<\(expected.end.map(String.init) ?? "end") (\(expected.voiced))")
        check(window.autoSelected == (start > 0 || end != nil), "seed \(seed): autoSelected means a part, not the whole")
        check(window.seconds < 181, "seed \(seed): the sample stays under 181 s")
    }
}

/// 说话、停顿长短不一；每四个里有一个只有不到 0.2 秒的小停顿（考退一步）。
private func randomLevels(seed: UInt64) -> [Float] {
    var random = SeededRandom(seed: seed)
    let solid = seed % 4 == 0
    let target = 9_500 + random.int(20_000)
    var levels: [Float] = []
    while levels.count < target {
        levels += [Float](repeating: 0.02 + Float(random.int(100)) / 400, count: 5 + random.int(solid ? 3_000 : 300))
        let pause = !solid && random.int(12) == 0 ? 250 + random.int(3_000) : 2 + random.int(solid ? 8 : 120)
        levels += [Float](repeating: Float(random.int(50)) / 20_000, count: pause)
    }
    return levels
}

/// 照方案直写：每个起点 × 3:00 前后 1 秒里每个格子边都看一遍能不能切，再按同样的先后挑；一个都没有才退到最安静的格子边。
private func bruteForce(_ levels: [Float], duration: Double) -> (start: Int, end: Int?, voiced: Int) {
    let count = levels.count
    let silent = levels.map { $0 < Window.speechRMSFloor }
    var sums = [0]
    for quiet in silent { sums.append(sums[sums.count - 1] + (quiet ? 0 : 1)) }
    func voiced(_ from: Int, _ to: Int) -> Int { sums[min(to, count)] - sums[from] }
    guard duration > 180 else { return (0, nil, voiced(0, count)) }
    var runLength = [Int](repeating: 0, count: count), runStart = [Int](repeating: 0, count: count)
    var index = 0
    while index < count {
        guard silent[index] else { index += 1; continue }
        var next = index
        while next < count, silent[next] { next += 1 }
        for frame in index..<next { runLength[frame] = next - index; runStart[frame] = index }
        index = next
    }
    func paused(_ frame: Int) -> Bool { frame >= 0 && frame < count && silent[frame] && runLength[frame] >= 10 }
    let starts = [0] + (2..<count).filter { !silent[$0] && paused($0 - 1) }.map { $0 - 2 }
    typealias Pick = (start: Int, end: Int?, voiced: Int, lead: Int)
    func pick(_ start: Int, _ end: Int?) -> Pick {
        let stop = end ?? count
        return (start, end, voiced(start, stop), voiced(start, min(stop, start + 750)))
    }
    func better(_ lhs: Pick, _ rhs: Pick) -> Bool {
        if lhs.voiced != rhs.voiced { return lhs.voiced > rhs.voiced }
        if lhs.lead != rhs.lead { return lhs.lead > rhs.lead }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return (lhs.end ?? Int.max) < (rhs.end ?? Int.max)
    }
    var picks: [Pick] = []
    for start in starts {
        if duration - Double(start) * 0.02 < 181 { picks.append(pick(start, nil)) }
        for cut in (start + 8_950)...(start + 9_049) where paused(cut - 2) && paused(cut + 1) && runStart[cut - 2] == runStart[cut + 1] {
            picks.append(pick(start, cut))
        }
    }
    if picks.isEmpty {
        for start in starts {
            let high = min(start + 9_049, count - 1)
            var cut = start + 8_950, quietest = Float.infinity
            if cut <= high {
                for boundary in cut...high where levels[boundary - 1] + levels[boundary] < quietest {
                    quietest = levels[boundary - 1] + levels[boundary]
                    cut = boundary
                }
            }
            picks.append(pick(start, cut))
        }
    }
    let best = picks.min(by: better)!
    return (best.start, best.end, best.voiced)
}

// MARK: 响度、WAV、写给 AI 的话

private func runMeterChecks() {
    var whole = Window.Meter(sampleRate: 44_100)
    checkEqual(whole.samplesPerFrame, 882, "a frame is 882 samples at 44.1 kHz")
    var random = SeededRandom(seed: 7)
    let samples = (0..<(882 * 40 + 300)).map { _ in Float(random.int(2_001) - 1_000) / 2_000 }
    whole.append(samples)
    var chunked = Window.Meter(sampleRate: 44_100)
    var position = 0
    while position < samples.count {
        let size = min(samples.count - position, 1 + random.int(1_500))
        chunked.append(Array(samples[position..<(position + size)]))
        position += size
    }
    checkEqual(chunked.levels, whole.levels, "reading in chunks measures exactly like reading at once")
    checkEqual(whole.levels.count, 40, "the 300-sample tail is not a frame")
    let first = (samples[0..<882].reduce(0.0) { $0 + Double($1) * Double($1) } / 882).squareRoot()
    check(abs(Double(whole.levels[0]) - first) < 1e-6, "a level is the frame's RMS")
}

private func runSampleFormatChecks() {
    checkEqual(VoiceReferenceSample.sampleRate, 44_100, "voice samples are 44.1 kHz (a 16 kHz sample made zonos2 run off the script)")
    checkEqual(VoiceReferenceSample.uploadPurpose, "voice_reference", "voice samples upload with the voice_reference purpose (35 MB)")
    checkEqual(VoiceReferenceSample.contentType, "audio/wav", "voice samples upload as WAV")
    let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 1_234]
    let wav = VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100)
    let header = WAVHeader(wav)
    checkEqual(wav.count, 44 + samples.count * 2, "a 44-byte header and the samples")
    checkEqual(header?.isMono16BitPCM, true, "RIFF / WAVE / fmt / data, PCM, mono, 16 bits")
    checkEqual(header?.sampleRate, 44_100, "the sample rate")
    checkEqual(header?.byteRate, 88_200, "bytes per second")
    checkEqual(header?.samples, samples, "the samples come back unchanged, including the extremes")
    checkEqual(VoiceReferenceSample.wavData(samples: [], sampleRate: 44_100).count, 44, "an empty sample is just a header")

    checkEqual(VoiceReferenceSample.quantize(1), 32_767, "full scale clamps to the largest sample")
    checkEqual(VoiceReferenceSample.quantize(-1), -32_768, "negative full scale is the smallest sample")
    checkEqual(VoiceReferenceSample.quantize(0.5), 16_384, "half scale")
    check((-32_768...32_767).allSatisfy { VoiceReferenceSample.quantize(Float($0) / 32_768) == Int16($0) },
          "every 16-bit sample survives the Float round trip")
    // 浮点源里的坏采样：以前 Int(_:) 在夹住之前就 trap，整个 App 崩掉（docs/bugfixes/2026-11-10-voice-reference-nan-sample-crash.md）。
    checkEqual([Float.nan, .infinity, -.infinity, 1e20, -1e20, .greatestFiniteMagnitude].map(VoiceReferenceSample.quantize),
               [0, 0, 0, 32_767, -32_768, 32_767], "NaN and ±infinity become silence, huge values clamp, nothing crashes")
    let tone = (0..<44_100).map { VoiceReferenceSample.quantize(0.1 * Float(sin(Double($0) * 0.0627))) }
    let hum = (0..<44_100).map { VoiceReferenceSample.quantize(0.003 * Float(sin(Double($0) * 0.0627))) }
    checkClose(VoiceReferenceSample.voicedSeconds(of: tone + [Int16](repeating: 0, count: 44_100) + hum), 1,
               "only the second at −20 dBFS counts as speech; silence and a −53 dBFS hum do not")

    checkEqual(VoiceReferenceSample.clock(72.4), "1:12", "minutes and seconds")
    checkEqual(VoiceReferenceSample.clock(3_725), "1:02:05", "hours when needed")
    checkEqual(VoiceReferenceSample.clock(180.5), "3:00", "rounded down: a 180.5 s sample never shows as 3:01 next to 'at most 3 minutes'")
    checkEqual(VoiceReferenceSample.spoken(180.5), "3 min 0 s", "speech time is rounded down too")
    checkEqual(VoiceReferenceSample.spoken(161), "2 min 41 s", "a long stretch of speech")
    checkEqual(VoiceReferenceSample.spoken(38.2), "38 s", "a short stretch of speech")
    let url = URL(fileURLWithPath: "/tmp/reference.wav")
    let auto = VoiceReferenceSample.Sample(url: url, sourceStart: 72, sourceEnd: 252, fileSeconds: 600, voicedSeconds: 161, autoSelected: true)
    checkEqual(auto.summary(name: "talk.mov"), "Voice sample: 1:12–4:12 of talk.mov, 2 min 41 s of clear speech, picked automatically "
               + "as the part with the most speech (a sample is at most 3 minutes).", "the result says which part was used")
    let all = VoiceReferenceSample.Sample(url: url, sourceStart: 0, sourceEnd: 42, fileSeconds: 42, voicedSeconds: 38, autoSelected: false)
    checkEqual(all.summary(name: "me.m4a"), "Voice sample: all of me.m4a (0:42), 38 s of clear speech.", "a whole recording")
}

/// 读回一个单声道 16-bit PCM 的 WAV（44 字节的头）。
struct WAVHeader {
    let isMono16BitPCM: Bool
    let sampleRate: UInt32
    let byteRate: UInt32
    let samples: [Int16]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 44 else { return nil }
        func text(_ at: Int) -> String { String(decoding: bytes[at..<(at + 4)], as: UTF8.self) }
        func le16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
        let size = Int(le32(40))
        guard text(0) == "RIFF", text(8) == "WAVE", text(12) == "fmt ", text(36) == "data", 44 + size <= bytes.count,
              Int(le32(4)) == 36 + size else { return nil }
        isMono16BitPCM = le32(16) == 16 && le16(20) == 1 && le16(22) == 1 && le16(32) == 2 && le16(34) == 16
        sampleRate = le32(24)
        byteRate = le32(28)
        samples = stride(from: 44, to: 44 + size, by: 2).map { Int16(bitPattern: le16($0)) }
    }
}

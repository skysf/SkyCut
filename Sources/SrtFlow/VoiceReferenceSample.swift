import Foundation

// MARK: - 克隆用的参考录音
//
// 管什么：从用户点名的音频 / 视频（可带起止秒）做出一段参考录音（SkyCut 声音方案第六节，决定第三节第 3 条）：
// 先把整段读一遍、20 ms 一格量响度，按 VoiceReferenceWindow 挑段（不到 3 分钟用整段，超过挑有效人声最多的连续 3 分钟）；
// 再只截那一段，写成 **44.1 kHz 单声道 16-bit WAV**，写好的采样按同一个口径再数一遍有效人声，不到 10 秒不收。
// 上传用途 `voice_reference`、类型 `audio/wav` 只在这里（Sky Studio 3.3：≤ 35 MB；3 分钟约 16 MB）。
// 阻塞读写都在 MediaReadQueue.analysis 上（VoiceReferenceReader）；取消只置停止标记。WAV 的写法只有 `wavData` 一份。
// 不管什么：读文件的授权（AIWorkspace.confirmReading）、上传本身（SkyStudioAPI.upload）、建声音 / 克隆生成。

enum VoiceReferenceSample {
    static var sampleRate: Double { VoiceReferenceReader.sampleRate }
    static let uploadPurpose = "voice_reference"
    static let contentType = "audio/wav"
    static let fileName = "reference.wav"

    /// 做好的参考录音：文件、用了原文件的哪一段、有效人声多少秒、是不是自动挑的。
    struct Sample: Equatable, Sendable {
        let url: URL
        /// 用的那一段在原文件里的起止秒。
        let sourceStart: Double
        let sourceEnd: Double
        /// 原文件多长（秒）。
        let fileSeconds: Double
        let voicedSeconds: Double
        /// 只用了给的那一段里的一部分（超过 3 分钟、自动挑的）。
        let autoSelected: Bool

        var seconds: Double { sourceEnd - sourceStart }

        /// 写给 AI / 用户的一句：用了哪一段、有效人声多少（方案第六节第 5 条）。
        func summary(name: String) -> String {
            let speech = "\(VoiceReferenceSample.spoken(voicedSeconds)) of clear speech"
            let whole = sourceStart < 0.05 && fileSeconds - sourceEnd < 0.05
            let part = whole ? "all of \(name) (\(VoiceReferenceSample.clock(seconds)))"
                : "\(VoiceReferenceSample.clock(sourceStart))–\(VoiceReferenceSample.clock(sourceEnd)) of \(name)"
            let picked = autoSelected ? ", picked automatically as the part with the most speech (a sample is at most 3 minutes)" : ""
            return "Voice sample: \(part), \(speech)\(picked)."
        }
    }

    /// 从 `source` 的 `[start, end)` 秒（end nil = 到结尾）做一段参考录音，写进 `folder/reference.wav`。
    static func prepare(from source: URL, start: Double = 0, end: Double? = nil, folder: URL) async throws -> Sample {
        let input = try await VoiceReferenceReader.Source.load(source)
        let from = max(0, start)
        let to = min(end ?? input.duration, input.duration)
        guard to - from >= VoiceReferenceWindow.frameSeconds else {
            throw AIToolError("That part of \(input.name) is empty: the file is \(clock(input.duration)) long.")
        }
        let stop = VoiceReferenceReader.Stop()
        return try await withTaskCancellationHandler {
            let scan = try await onReadQueue { () -> (levels: [Float], count: Int) in
                var meter = VoiceReferenceWindow.Meter(sampleRate: sampleRate)
                let count = try VoiceReferenceReader.read(input, from: from, to: to, stop: stop) { meter.append($0) }
                return (meter.levels, count)
            }
            let window = VoiceReferenceWindow.choose(levels: scan.levels, duration: Double(scan.count) / sampleRate)
            try requireSpeech(window.voicedSeconds, name: input.name)
            let samples = try await onReadQueue { () -> [Int16] in
                var quantized: [Int16] = []
                quantized.reserveCapacity(Int(window.seconds * sampleRate) + 1)
                _ = try VoiceReferenceReader.read(input, from: from + window.start, to: from + window.end, stop: stop) { chunk in
                    quantized.append(contentsOf: chunk.lazy.map(quantize))
                }
                return quantized
            }
            // 再数一遍的是要上传的那些采样本身（服务器解出来的就是它们）。
            let voiced = voicedSeconds(of: samples)
            try requireSpeech(voiced, name: input.name)
            let url = folder.appendingPathComponent(fileName)
            let data = wavData(samples: samples, sampleRate: Int(sampleRate))
            try await onReadQueue {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            let begin = from + window.start
            return Sample(url: url, sourceStart: begin, sourceEnd: begin + Double(samples.count) / sampleRate,
                          fileSeconds: input.duration, voicedSeconds: voiced, autoSelected: window.autoSelected)
        } onCancel: { stop.stop() }
    }

    /// 有效人声多少秒：16-bit 采样按服务器解码的方式换回 Float（÷ 32768），20 ms 一格、−45 dBFS 的门限（VoiceReferenceWindow）。
    static func voicedSeconds(of samples: [Int16]) -> Double {
        var meter = VoiceReferenceWindow.Meter(sampleRate: sampleRate)
        meter.append(samples.map { Float($0) / 32_768 })
        return VoiceReferenceWindow.seconds(frames: VoiceReferenceWindow.voicedFrames(levels: meter.levels))
    }

    /// −1…1 的 Float → 16-bit（×32768 四舍五入、夹在范围里）：16-bit 的源原样回来，一个采样都不变。
    static func quantize(_ value: Float) -> Int16 {
        Int16(clamping: Int((Double(value) * 32_768).rounded()))
    }

    /// 单声道 16-bit PCM 的 WAV：44 字节的头 + 小端采样。
    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let bytes = samples.count * 2
        var data = Data()
        data.reserveCapacity(44 + bytes)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); append32(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: "data".utf8); append32(UInt32(bytes))
        samples.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    // MARK: 内部

    private static func requireSpeech(_ voiced: Double, name: String) throws {
        let minimum = VoiceReferenceWindow.minimumVoicedSeconds
        guard voiced < minimum else { return }
        // 有的往下取、差的往上取（到 0.1 秒）：两个数加起来不少于 10，也不会写出「还差 0.0 秒」。
        let have = (voiced * 10).rounded(.down) / 10
        let missing = max(0.1, ((minimum - voiced) * 10).rounded(.up) / 10)
        throw AIToolError(
            "\(name) has only \(String(format: "%.1f", have)) s of clear speech there; a voice sample needs at least "
                + "\(Int(minimum)) s (\(String(format: "%.1f", missing)) s more). Use a recording of one person talking for "
                + "30 s to 1 min without music.",
            details: ["reason": "too_little_speech", "voiced_seconds": .number(have), "required_seconds": .number(minimum),
                      "missing_seconds": .number(missing)]
        )
    }

    private static func onReadQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try work() } }.get()
    }

    /// `72.4` → `1:12`，`3725` → `1:02:05`（整秒）。
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// `161` → `2 min 41 s`，`38.2` → `38 s`。
    static func spoken(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }
}

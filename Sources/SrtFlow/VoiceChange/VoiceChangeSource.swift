import Foundation

// MARK: - 变声的源：这一段能不能变、从素材里截出要上传的那段声音
//
// 管什么（SkyCut 声音方案 4.8 第 1、3 步）：
// - 哪些段能变声：有声音、没静音的视频段和音频段（图片段没有声音）；超过 Sky Studio 的一次上限（`/models` 的
//   `limits.max_source_seconds`，现在 5 分钟）的拒、话里建议先分割；几乎没声音的拒。
// - 截：这一段的源时间范围 `[sourceStart, sourceStart + sourceDuration)` → **单声道 16-bit WAV**，采样率取原素材的、最高 48 kHz
//   （5 分钟约 29 MB，在 35 MB 的上传上限以内）。素材的声音比这一段先完就补零到这一段的长度：服务器把变声后的人声补到源音频那么长，
//   源短了两条新轨就都短了。读法和参考录音同一份（VoiceReferenceReader：按 PTS 落格、立体声取平均），阻塞读只在 MediaReadQueue.analysis 上。
// - 「几乎没声音」：20 ms 一格、均方根 ≥ 0.0056 的格子加起来不到 0.5 秒（门限是这里自己的常量，不借参考录音和服务器的那个合同）。
// 两个入口同一条路：AI 的 change_voice（VoiceChangeTool）和片段右键的面板（VoiceChangePanelModel）都只调 `prepare`。
// 不管什么：报价、交任务（VoiceChangeOrder / VoiceChangeJob）、落到时间线上（VoiceChangeLanding）。

/// 这一段变不了声的原因（给 AI 的英文在 `message`；面板照界面语言写，VoiceChangeText）。
enum VoiceChangeProblem: Error, Equatable {
    /// 没有声音的段（没有音轨的视频、图片）。
    case noSound(name: String)
    /// 已经静音的段：变出来也听不见。
    case muted(name: String)
    /// 超过一次的上限（秒）。
    case tooLong(seconds: Double, limit: Double)
    /// 几乎没声音。
    case almostSilent(name: String)
    /// 截出来的文件超过上传上限（35 MB）。
    case tooLarge

    var message: String {
        switch self {
        case .noSound(let name):
            return "\(name) has no sound to re-voice."
        case .muted(let name):
            return "\(name) is muted; unmute it first (edit_clip muted=false) so there is a voice to change."
        case .tooLong(let seconds, let limit):
            return String(format: "This clip uses %.1f s of its source; Sky Studio changes at most %.0f s of voice at a time. "
                + "Split it first (split_clip) and change each part. Nothing was charged.", seconds, limit)
        case .almostSilent(let name):
            return "\(name) is almost silent: there is no voice to change. Nothing was charged."
        case .tooLarge:
            return "The clip's sound is too large to upload (at most 35 MB); split it first (split_clip). Nothing was charged."
        }
    }
}

enum VoiceChangeSource {
    /// 上传的采样率：原素材的，最高 48 kHz；读不出来按 44.1 kHz。
    static let maxSampleRate = 48_000.0
    static let fallbackSampleRate = 44_100.0
    static let contentType = "audio/wav"
    static let fileName = "voice-change-source.wav"
    /// 一格（20 ms）的均方根到这个数才算有声（约 −45 dBFS）；这里自己的常量。
    static let soundRMSFloor: Float = 0.0056
    /// 有声的格子加起来不到这么多秒：几乎没声音。
    static let minimumSoundSeconds = 0.5

    /// 截好的那段：WAV 在哪、对应素材的哪一段、多长、有声多少秒。
    struct Prepared: Equatable, Sendable {
        let url: URL
        /// 截的是哪个素材的哪一段（落地时核对这一段还盖不盖得住，VoiceChangeLanding.Origin）。
        let sourceURL: URL
        let sourceStart: Double
        /// 写出来的 WAV 多长（秒）= 这一段的源秒数；报价按它。
        let seconds: Double
        let sampleRate: Double
        let soundSeconds: Double
        let bytes: Int
    }

    /// 光看这一段本身变不变得了（不读文件）：没有声音、已经静音。
    static func refusal(for clip: EditClip) -> VoiceChangeProblem? {
        guard clip.hasAudio, !clip.isStillImage else { return .noSound(name: clip.name) }
        return clip.isMuted ? .muted(name: clip.name) : nil
    }

    /// 超过一次的上限了没有（`limit` 读不到就不在本机拦，服务器照样会拦）。给一点点余量：正好 5 分钟的段不因为浮点误差被拒。
    static func tooLong(_ clip: EditClip, limit: Double?) -> VoiceChangeProblem? {
        guard let limit, limit > 0, clip.sourceDuration > limit + 0.0005 else { return nil }
        return .tooLong(seconds: clip.sourceDuration, limit: limit)
    }

    static func sampleRate(native: Double?) -> Double {
        guard let native, native.isFinite, native >= 8_000 else { return fallbackSampleRate }
        return min(native, maxSampleRate)
    }

    /// 截出这一段的声音，写进 `folder/voice-change-source.wav`。被拒、被取消都不留文件。
    static func prepare(_ clip: EditClip, folder: URL) async throws -> Prepared {
        if let problem = refusal(for: clip) { throw problem }
        let input = try await VoiceReferenceReader.Source.load(clip.sourceURL)
        let rate = sampleRate(native: input.nativeSampleRate)
        let from = max(0, clip.sourceStart)
        let wanted = max(0, clip.sourceDuration)
        let to = min(from + wanted, input.duration)
        guard wanted >= 0.1, to > from else { throw VoiceChangeProblem.noSound(name: clip.name) }
        let frames = Int((wanted * rate).rounded())
        let stop = VoiceReferenceReader.Stop()
        return try await withTaskCancellationHandler {
            let read = try await onReadQueue { () -> (samples: [Int16], sound: Double) in
                var meter = VoiceReferenceWindow.Meter(sampleRate: rate)
                var quantized: [Int16] = []
                quantized.reserveCapacity(frames)
                _ = try VoiceReferenceReader.read(input, from: from, to: to, stop: stop, rate: rate) { chunk in
                    meter.append(chunk)
                    quantized.append(contentsOf: chunk.lazy.map(VoiceReferenceSample.quantize))
                }
                // 素材的声音比这一段先完：补零到这一段的长度（两条新轨和原片段一样长）。
                if quantized.count < frames { quantized.append(contentsOf: repeatElement(0, count: frames - quantized.count)) }
                let voiced = meter.levels.reduce(0) { $0 + ($1 >= soundRMSFloor ? 1 : 0) }
                return (quantized, VoiceReferenceWindow.seconds(frames: voiced))
            }
            guard read.sound >= minimumSoundSeconds else { throw VoiceChangeProblem.almostSilent(name: clip.name) }
            let data = VoiceReferenceSample.wavData(samples: read.samples, sampleRate: Int(rate))
            guard SkyStudioVoiceUpload.fits(bytes: data.count) else { throw VoiceChangeProblem.tooLarge }
            // 取消晚到（读完之后、写之前）也不写。
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(fileName)
            try await onReadQueue {
                try stop.check()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return Prepared(url: url, sourceURL: clip.sourceURL, sourceStart: from, seconds: Double(read.samples.count) / rate,
                            sampleRate: rate, soundSeconds: read.sound, bytes: data.count)
        } onCancel: { stop.stop() }
    }

    private static func onReadQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try work() } }.get()
    }
}

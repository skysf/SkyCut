import AVFoundation
import Foundation
import SrtFlowCore

// 按源区间抽音频（docs/plans/2026-08-06-native-subtitle-generation.md 11.3）。
//
// 走计划里的稳妥路径：AVAssetReader 按 timeRange 读 16k/16bit/单声道 PCM，
// 落成临时 CAF，喂 SpeechAnalyzer 的 inputAudioFile（官方支持的文件输入，
// Phase 0 spike 已实测跑通）。窗口级临时文件用完即删，defer 兜底；
// 内存里永远只有一个采样块。
//
// **`extract` 只许字幕生成（SubtitleGen/）调**：它的读取循环写在 async 函数里，是 checks/blocking-media-reads.sh 白名单上唯一的例外，
// 理由只对字幕生成成立（严格一个窗口读完再读下一个）。别处要同样的 CAF（配旁白回来的音频、新建声音时检测语言）走
// QueuedAudioWindow：同一份格式和落盘（下面的零件），读取在 MediaReadQueue 上跑。守卫钉着调用方。

enum AudioWindowReader {

    /// 素材本身读不了（缺音轨、解码失败……）：调用方可按「单素材跳过」处理。
    struct ReadError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 我们自己的基础设施出问题（临时文件建不了、PCM 格式造不出……）：
    /// **不是**素材的错，调用方必须整体失败并保留原始原因，
    /// 不得误报成「素材不可读」。
    struct InfrastructureError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 16kHz/mono/Int16 —— Phase 0 实测的 bestAvailableAudioFormat。
    static let sampleRate = 16_000.0

    /// 把素材的一段源区间抽成临时 CAF。返回文件 URL；
    /// 词时间 = 文件内时间 + range.start（调用方补偿）。
    static func extract(
        assetURL: URL,
        range: SourceRange,
        into directory: URL,
        isCancelled: @escaping () -> Bool
    ) async throws -> URL {
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError(message: String(
                format: L10n("“%@” has no audio track."), assetURL.lastPathComponent
            ))
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: range.duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let target = try makeFile(in: directory)

        guard reader.startReading() else {
            throw reader.error ?? ReadError(message: "Audio reader failed to start.")
        }
        defer { reader.cancelReading() }

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            try append(sample, to: target.file, format: target.format)
        }
        if let error = reader.error { throw error }
        return target.url
    }

    // MARK: 两个读取器共用的零件（这里的 `extract` 和 MediaReadQueue 上跑的 QueuedAudioWindow）：格式、临时文件、一块采样怎么落盘只有一份

    /// 16 kHz / 单声道 / 16-bit 整数 PCM。
    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 在 `directory` 里开一个临时 CAF。建不出来是我们的问题（磁盘满 / 权限），不是素材的。
    static func makeFile(in directory: URL) throws -> (file: AVAudioFile, url: URL, format: AVAudioFormat) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        ) else {
            throw InfrastructureError(message: "Failed to create PCM format.")
        }
        let fileURL = directory.appendingPathComponent("window-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            return (file, fileURL, format)
        } catch {
            throw InfrastructureError(message: error.localizedDescription)
        }
    }

    /// 把读到的一块采样接到 CAF 后面。空块跳过。
    static func append(_ sample: CMSampleBuffer, to file: AVAudioFile, format: AVAudioFormat) throws {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return }
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        ) else {
            // 静默跳块 = 半截 CAF 照常转写、缺失区间被记成已覆盖，
            // 重跑也不会补 —— 必须整体失败（评审 P2）。
            throw InfrastructureError(message: "Failed to allocate PCM buffer.")
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        guard status == noErr else {
            throw ReadError(message: "PCM copy failed (\(status)).")
        }
        do {
            try file.write(from: pcm)
        } catch {
            // 写盘失败（磁盘满等）同样是基础设施问题。
            throw InfrastructureError(message: error.localizedDescription)
        }
    }

    /// 启动残留清理：上次崩溃 / 强退留下的 SrtFlow-ASR-* 临时目录（转写抽出来的音频窗口都写在这种目录里）。
    /// 2026-09-26 从 TranscriptionTask 搬来（那个文件贴着 600 行的上限）。
    static func sweepTempResidue() {
        let manager = FileManager.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? manager.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        ) else { return }
        for item in items where item.lastPathComponent.hasPrefix("SrtFlow-ASR-") {
            try? manager.removeItem(at: item)
        }
    }
}

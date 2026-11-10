import AVFoundation
import Foundation
import SrtFlowCore

// MARK: - 抽一段音频给转写用，读取在 MediaReadQueue 上跑
//
// 管什么：和 AudioWindowReader.extract 同一种产物（16 kHz 单声道 16-bit 的临时 CAF，格式、建文件、落盘用它那几样零件），
// 给**字幕生成以外**的调用方：配旁白回到本机的音频要转写（SkyStudioVoiceAudio，`MediaReadQueue.voice`）、新建声音时检测录音的语言
// （VoiceSampleLanguage，`MediaReadQueue.analysis`）。`loadTracks` 在 async 里做完，「建 reader → 读 → 写」是单独的同步函数、只在
// 调用方点名的那条队列的线程上跑（docs/architecture/blocking-media-reads.md）：不占 Swift 并发的线程池。
// 取消：外面只置停止标记，读取体在每次 copy 之前看它；reader 的 `cancelReading` 只在读取体自己的 defer 里（它不许和 copy 并发）。
// 被取消 / 出错时半截文件留在 `directory` 里，由调用方连文件夹一起删。
// 不管什么：字幕生成按窗口抽（AudioWindowReader.extract，那个例外）、转写（SpeechTranscriptionService）。

enum QueuedAudioWindow {
    static func extract(assetURL: URL, range: SourceRange, into directory: URL, on queue: OperationQueue) async throws -> URL {
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioWindowReader.ReadError(message: String(format: L10n("“%@” has no audio track."), assetURL.lastPathComponent))
        }
        let source = Source(asset: asset, track: track)
        let stop = Stop()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await MediaReadQueue.run(on: queue) { Result { try read(source, range: range, into: directory, stop: stop) } }.get()
        } onCancel: { stop.stop() }
    }

    /// 加载好的素材：之后只在读取队列上碰（AVAsset 不是 Sendable，加载完不再改）。
    private struct Source: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
    }

    /// 停止标记：读取在 OperationQueue 的线程上，看不见 Task 的取消。
    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.withLock { stopped = true } }
        func check() throws { if lock.withLock({ stopped }) { throw CancellationError() } }
    }

    /// 同步阻塞段：**只在 MediaReadQueue 的线程上调。**
    private static func read(_ source: Source, range: SourceRange, into directory: URL, stop: Stop) throws -> URL {
        try stop.check()
        let reader = try AVAssetReader(asset: source.asset)
        // 唯一的取消点和 copy 在同一个同步读取体里。
        defer { reader.cancelReading() }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                       duration: CMTime(seconds: range.duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: AudioWindowReader.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioWindowReader.ReadError(message: "Audio reader cannot decode this file.") }
        reader.add(output)
        let target = try AudioWindowReader.makeFile(in: directory)
        guard reader.startReading() else { throw reader.error ?? AudioWindowReader.ReadError(message: "Audio reader failed to start.") }
        while true {
            try stop.check()
            guard let sample = output.copyNextSampleBuffer() else { break }
            try AudioWindowReader.append(sample, to: target.file, format: target.format)
        }
        try stop.check()
        if let error = reader.error { throw error }
        return target.url
    }
}

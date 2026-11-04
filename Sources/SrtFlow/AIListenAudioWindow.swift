import AVFoundation
import Foundation

// 管什么：listen 点名文件区间的原生有界读取，复用 ChunkBuilder 攒峰值/均方；只保存这一窗。
// 不管什么：共享的整文件波形、AI 参数和权限、节拍、试听。阻塞循环只在 MediaReadQueue.analysis 上跑。

enum AIListenAudioWindow {
    /// 内部生产读取探针：自检等待真实 start/finish，不以 sleep 或别的队列任务推测 reader 状态。
    enum Event: Sendable { case started, finished }
    /// 生命周期守卫可替换 reader 并记录原生收尾；实际工具默认仍建同一个 AVAssetReader。
    typealias ReaderFactory = @Sendable (AVAsset) throws -> AVAssetReader
    struct Reading: Sendable {
        var peaks: WaveformPeaks
        /// 本地波形第零帧对应的源秒；压缩音频按真实 PTS 裁掉包边界外的采样。
        var sourceStart: Double
        var from: Double
        var to: Double
        var fileDuration: Double
        /// 原生 reader 实际交出的采样数与时间范围，供生产路径回归核实有界读取。
        var decodedFrames: Int
        var decodedFrom: Double
        var decodedTo: Double

        var windows: [AIAudioLevels.Window] {
            AIAudioLevels.windows(peaks, from: 0, to: peaks.duration).map {
                var moved = $0
                moved.start += sourceStart
                moved.end += sourceStart
                return moved
            }
        }
    }

    static func duration(of url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AIToolError("SkyCut could not determine this file's duration.") }
        return duration
    }

    static func read(
        _ url: URL, from: Double?, to: Double?, until deadline: Date,
        observe: (@Sendable (Event) -> Void)? = nil,
        readerFactory: ReaderFactory? = nil
    ) async throws -> Reading {
        let asset = AVURLAsset(url: url)
        let control = AIListenReadControl(asset: asset)
        control.start(until: deadline)
        defer { control.finish() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try control.check()
                let duration = try await asset.load(.duration).seconds
                try control.check()
                guard duration.isFinite, duration > 0 else { throw AIToolError("SkyCut could not determine this file's duration.") }
                let start = max(0, from ?? 0)
                let end = min(to ?? duration, duration)
                guard end > start else {
                    throw AIToolError("source_out must be after source_in, within the file's \(String(format: "%.2f", duration)) s duration.")
                }
                guard let found = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw AIToolError("\(url.lastPathComponent) has no sound SkyCut can read.")
                }
                try control.check()
                let formats = try await found.load(.formatDescriptions)
                try control.check()
                let channels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
                nonisolated(unsafe) let track = found
                return try await control.run {
                    try read(asset, track: track, channels: Int(channels), from: start, to: end,
                             duration: duration, control: control, observe: observe, readerFactory: readerFactory)
                }
            } catch {
                try control.check()
                throw error
            }
        } onCancel: { control.cancel() }
    }

    /// 同步阻塞段：timeRange 限制解码，PTS 再限制进统计的采样；失败/取消不发布半份结果。
    private static func read(
        _ asset: AVURLAsset, track: AVAssetTrack, channels: Int, from: Double, to: Double,
        duration: Double, control: AIListenReadControl, observe: (@Sendable (Event) -> Void)?, readerFactory: ReaderFactory?
    ) throws -> Reading {
        try control.check()
        let reader = try readerFactory?(asset) ?? AVAssetReader(asset: asset)
        // 唯一取消点与 copy 在同一个同步读取体；外部超时/取消不能拆掉还在 copy 的原生对象。
        defer { reader.cancelReading(); observe?(.finished) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings(channels: channels))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AIToolError("SkyCut could not decode this audio range.") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600_000),
                                       end: CMTime(seconds: to, preferredTimescale: 600_000))
        try control.check()
        guard reader.startReading() else { throw reader.error ?? AIToolError("SkyCut could not start reading this audio range.") }
        try control.check()
        observe?(.started)
        var accumulation = Accumulation()
        while true {
            try control.check()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            try control.check()
            try accumulation.append(buffer, from: from, to: to)
        }
        try control.check()
        guard reader.status == .completed else { throw reader.error ?? AIToolError("SkyCut could not finish reading this audio range.") }
        return try accumulation.finish(from: from, to: to, duration: duration)
    }

    private static func outputSettings(channels: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: min(2, max(1, channels))
        ]
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    private struct Accumulation {
        var builder: ChunkBuilder?
        var chunks: [WaveformChunk] = []
        var sampleRate = 0.0
        var sourceStart = 0.0
        var decodedFrames = 0
        var decodedFrom = Double.infinity
        var decodedTo = -Double.infinity
        var storedFrames = 0

        mutating func append(_ buffer: CMSampleBuffer, from: Double, to: Double) throws {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate > 0 else { throw AIToolError("SkyCut could not read this range's audio format.") }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time.isFinite else { throw AIToolError("SkyCut could not locate this range's audio samples.") }
            let rate = asbd.mSampleRate
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = CMSampleBufferGetNumSamples(buffer)
            decodedFrames += frames
            decodedFrom = min(decodedFrom, time)
            decodedTo = max(decodedTo, time + Double(frames) / rate)
            let first = min(frames, max(0, Int(ceil((from - time) * rate - 1e-6))))
            let last = min(frames, max(0, Int(ceil((to - time) * rate - 1e-6))))
            guard last > first else { return }
            if builder == nil {
                sampleRate = rate
                sourceStart = time + Double(first) / rate
                builder = ChunkBuilder(channels: channels, startFrame: 0)
            }
            let start = time + Double(first) / rate
            guard abs(rate - sampleRate) < 0.01,
                  abs(start - sourceStart - Double(storedFrames) / rate) <= 2 / rate,
                  abs(sourceStart - from) <= 2 / rate else {
                throw AIToolError("This source range has discontinuous or missing audio coverage; no complete audio report was returned.")
            }
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
            )
            guard status == noErr, let data = list.mBuffers.mData,
                  Int(list.mBuffers.mDataByteSize) >= frames * channels * MemoryLayout<Float>.size else {
                throw AIToolError("SkyCut could not read this range's audio samples.")
            }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self) + first * channels,
                                              count: (last - first) * channels)
            builder?.append(interleaved: samples) { chunks.append($0) }
            storedFrames += last - first
        }

        mutating func finish(from: Double, to: Double, duration: Double) throws -> Reading {
            guard var builder else { throw AIToolError("No audio samples were found in the requested source range.") }
            guard abs(sourceStart + Double(storedFrames) / sampleRate - to) <= 2 / sampleRate else {
                throw AIToolError("This source range has incomplete audio coverage; no complete audio report was returned.")
            }
            if let tail = builder.finishChunk() { chunks.append(tail) }
            return Reading(peaks: WaveformPeaks(sampleRate: sampleRate, channelCount: builder.channels,
                                               chunks: chunks, isComplete: true),
                           sourceStart: sourceStart, from: from, to: to, fileDuration: duration,
                           decodedFrames: decodedFrames, decodedFrom: decodedFrom, decodedTo: decodedTo)
        }
    }
}

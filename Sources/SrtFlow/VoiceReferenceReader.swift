import AVFoundation
import Foundation

// MARK: - 读克隆参考录音的声音（AVFoundation 适配）
//
// 管什么：用户点名的音频 / 视频 → 44.1 kHz 单声道 Float 采样，一块一块交出去。立体声取左右平均；多于两声道先让
// AVFoundation 按立体声布局混下来（同 AIListenAudioWindow）。按 PTS 落到采样格上：第 n 个采样就是 `from + n / 44100`
// 秒，缺的补零、重叠的丢掉，挑段算的时间和截出来的采样对得上。
// 变声的源（VoiceChangeSource，声音 PR 9）用同一个读法、换一个采样率（`rate`：原素材的、最高 48 kHz）；参考录音永远是 44.1 kHz。
// 阻塞的读取循环只在调用方交来的 MediaReadQueue 线程上跑（docs/architecture/blocking-media-reads.md）；
// reader 的 `cancelReading` 只在读取体自己的 defer 里（它不许和 copyNextSampleBuffer 并发），外面只置停止标记。
// 不管什么：挑哪一段（VoiceReferenceWindow）、写 WAV 和上传（VoiceReferenceSample）。

enum VoiceReferenceReader {
    /// 参考录音的采样率：44.1 kHz（16 kHz 的中文参考 zonos2 读出 44 秒、后半段跑稿，同一段 44.1 kHz 正常，
    /// zonos2-test-2026-11-08 zh-A / zh-B；之后各轮实测都用这个规格）。
    static let sampleRate = 44_100.0
    /// 读的时候两头各多读的秒数（只给重采样器当余量，不进结果）。
    private static let readMargin = 0.1

    /// 读之前在 async 里加载好的素材；之后只在读取队列上碰（AVAsset 不是 Sendable，加载完不再改）。
    struct Source: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let channels: Int
        let duration: Double
        /// 素材自己的采样率（读不出来是 nil）；参考录音不看它，变声的源照它读（最高 48 kHz）。
        var nativeSampleRate: Double?
        var name: String { asset.url.lastPathComponent }

        static func load(_ url: URL) async throws -> Source {
            let name = url.lastPathComponent
            let asset = AVURLAsset(url: url)
            let duration: Double
            let found: AVAssetTrack?
            do {
                duration = try await asset.load(.duration).seconds
                found = try await asset.loadTracks(withMediaType: .audio).first
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AIToolError("SkyCut could not read \(name) as audio or video: \(error.localizedDescription)")
            }
            guard let track = found else { throw AIToolError("\(name) has no sound to make a voice sample from.") }
            guard duration.isFinite, duration > 0 else { throw AIToolError("SkyCut could not tell how long \(name) is.") }
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let basic = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let native = basic.map(\.mSampleRate).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Source(asset: asset, track: track, channels: max(1, Int(basic?.mChannelsPerFrame ?? 2)), duration: duration,
                          nativeSampleRate: native)
        }
    }

    /// 停止标记：读取在 OperationQueue 的线程上，看不见 Task 的取消，用这个盒子传（同 UpscaleCancelFlag）。
    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.withLock { stopped = true } }
        func check() throws { if lock.withLock({ stopped }) { throw CancellationError() } }
    }

    /// 同步阻塞段：读 `[from, to)` 秒，单声道 `rate`（默认 44.1 kHz）一块一块交给 `consume`，回交出去的采样数（声音比 `to` 先完就少）。
    /// **只在 MediaReadQueue 的线程上调。**
    static func read(_ source: Source, from: Double, to: Double, stop: Stop, rate: Double = sampleRate,
                     consume: (UnsafeBufferPointer<Float>) -> Void) throws -> Int {
        try stop.check()
        let reader = try AVAssetReader(asset: source.asset)
        // 唯一的取消点和 copy 在同一个同步读取体里；外面的取消只让循环在下一次 copy 之前停。
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: outputSettings(channels: source.channels, rate: rate))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AIToolError("SkyCut could not decode the sound in \(source.name).") }
        reader.add(output)
        // 前后各多读 0.1 秒：重采样器两头要一点余量（48 kHz 的源只读 [from, to) 时末尾会少几十个采样）；多出来的按 PTS 丢掉。
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from - readMargin), preferredTimescale: 600_000),
                                       end: CMTime(seconds: min(to + readMargin, source.duration), preferredTimescale: 600_000))
        guard reader.startReading() else { throw reader.error ?? AIToolError("SkyCut could not start reading \(source.name).") }
        var grid = Grid(from: from, limit: Int(((to - from) * rate).rounded()), rate: rate)
        while true {
            try stop.check()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            try grid.append(buffer, name: source.name, consume: consume)
        }
        try stop.check()
        guard reader.status == .completed else { throw reader.error ?? AIToolError("SkyCut could not finish reading \(source.name).") }
        return grid.written
    }

    private static func outputSettings(channels: Int, rate: Double) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: min(2, max(1, channels))
        ]
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    /// 解码出来的交错采样 → 单声道，落到从 `from` 起的采样格上（按 PTS：缺的补零、重叠的丢掉、到 `limit` 为止）。
    private struct Grid {
        let from: Double
        let limit: Int
        let rate: Double
        private(set) var written = 0
        private var mono: [Float] = []

        init(from: Double, limit: Int, rate: Double) { self.from = from; self.limit = max(0, limit); self.rate = rate }

        mutating func append(_ buffer: CMSampleBuffer, name: String, consume: (UnsafeBufferPointer<Float>) -> Void) throws {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, written < limit else { return }
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  abs(description.mSampleRate - rate) < 0.5 else {
                throw AIToolError("SkyCut could not convert the sound in \(name) to \(Self.kilohertz(rate)) kHz.")
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time.isFinite else { throw AIToolError("SkyCut could not place the sound samples of \(name) in time.") }
            let channels = max(1, Int(description.mChannelsPerFrame))
            var block: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
            )
            guard status == noErr, let data = list.mBuffers.mData,
                  Int(list.mBuffers.mDataByteSize) >= frames * channels * MemoryLayout<Float>.size else {
                throw AIToolError("SkyCut could not read the sound samples of \(name).")
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            // 这一块第一个采样落在第几格：后面的缺口补零，前面重叠的丢掉。
            let offset = Int(((time - from) * rate).rounded())
            if offset > written { pad(min(offset, limit) - written, consume: consume) }
            let skip = max(0, written - offset)
            let take = min(frames - skip, limit - written)
            guard take > 0 else { return }
            mono.removeAll(keepingCapacity: true)
            mono.reserveCapacity(take)
            for frame in skip..<(skip + take) {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono.append(sum / Float(channels))
            }
            mono.withUnsafeBufferPointer { consume($0) }
            written += take
        }

        /// `44100` → `44.1`，`48000` → `48`。
        private static func kilohertz(_ rate: Double) -> String {
            let value = rate / 1000
            return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }

        /// 补零：一秒一块交出去，长的缺口（声音晚开头、中间断了）也不一次分配一大块。
        private mutating func pad(_ count: Int, consume: (UnsafeBufferPointer<Float>) -> Void) {
            guard count > 0 else { return }
            let zeros = [Float](repeating: 0, count: min(count, Int(rate)))
            var left = count
            while left > 0 {
                let piece = min(left, zeros.count)
                zeros.withUnsafeBufferPointer { consume(UnsafeBufferPointer(rebasing: $0.prefix(piece))) }
                left -= piece
            }
            written += count
        }
    }
}

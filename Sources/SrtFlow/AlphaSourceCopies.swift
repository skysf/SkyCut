import Accelerate
import AVFoundation
import CryptoKit
import Darwin
import Foundation

// MARK: - 带透明的视频：AVFoundation 那一边要用的两份副本（预乘副本、灰度遮罩）
//
// 管什么（长期约束见 docs/architecture/freeze-frame.md 第 4a3 节「带透明的段」）：
// - **直通的源 → 预乘的 ProRes 4444**：预览的默认合成器把源一律当预乘的用、不看文件里的标记，直通的半透明处会过亮（光成了
//   一条白带）；AVFoundation 里没有「按标记预乘」的开关（2026-11-16 查过、试过），只能换一份预乘过的源。预览、AI 的 look、
//   带关键帧段的预渲染都读它；成片读原片（ffmpeg 按直通叠，`ExportTransformChain`）。The preview only takes it once it is on
//   disk (`readyURL`) — it never waits for a conversion; the optimized-media coordinator has it made and swaps it in (2026-11-17).
// - **带透明的源 → 灰度遮罩**（白 = 不透明，ProRes 422，没有 alpha）：带关键帧的上层轨段走 fill + matte 预渲染，matte 要是
//   源自己的 alpha（同透明静帧的那份遮罩），纯白的话透明的地方照样不透明。
// 两份都**逐帧照抄时间戳、照抄旋转矩阵**：和原片逐帧对得上，段的起止、变速、关键帧一个数都不用换算。按「路径 + 文件身份 + 版本」
// 缓存在 ~/Library/Caches/SrtFlow/AlphaSources/，丢了重转；同一份同时只转一次。读和写都会卡住线程，在 `MediaReadQueue.alpha` 上跑。
// 不管什么：哪一段带透明、预乘还是直通（`SourceAlpha` / `EditClip.sourceAlpha`）；合成里换哪条轨（`CompositionSource`）；
// 遮罩怎么用（`AnimatedClipPrerenderer`）。

enum AlphaSourceCopies {
    enum Kind: String, Sendable {
        /// 直通的源转成预乘的 ProRes 4444（标明预乘）。
        case premultiplied = "premult"
        /// 源的 alpha 抽成不透明的灰度片。
        case matte
    }

    /// 改转法（编码、像素格式、几何、时间戳的抄法）要 +1：旧的副本就不认了。
    static let version = 1

    /// 这个源的那一份副本：缓存里有就直接给，没有就转（同一份同时只转一次，后来的等先来的那一趟）。转不出来是 nil。
    static func url(_ kind: Kind, for source: URL) async -> URL? {
        guard let target = cacheURL(kind, for: source) else { return nil }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        return await Flights.shared.run(target) { await convert(kind, source: source, to: target) }
    }

    /// The copy if it is already on disk — never converts, never waits. The preview rebuild asks this (it shows the original
    /// until the copy is made, `CompositionSource.track`); a half-written copy is never at this path (it is moved in when done).
    static func readyURL(_ kind: Kind, for source: URL) -> URL? {
        guard let target = cacheURL(kind, for: source), FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    /// 副本该放在哪（不管转没转）：文件名里带源的路径和身份（inode、卷、大小、修改时间）—— 原地改写过、换了文件都是另一份。
    /// 源不在、缓存目录建不出来 = nil。
    static func cacheURL(_ kind: Kind, for source: URL) -> URL? {
        var info = stat()
        guard stat(source.path, &info) == 0,
              let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("SrtFlow/AlphaSources", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let identity = "\(source.path)|\(info.st_ino)|\(info.st_dev)|\(info.st_size)|"
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        let key = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key)-\(kind.rawValue)-v\(version).mov")
    }

    /// 在 async 里把源的几样属性加载好，阻塞的读和写交给 `MediaReadQueue.alpha`（登记成后台读：冒烟的「落定」等它）。
    private static func convert(_ kind: Kind, source: URL, to target: URL) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform, range) = try? await track.load(.naturalSize, .preferredTransform, .timeRange),
              natural.width >= 1, natural.height >= 1 else { return nil }
        let job = Job(kind: kind, asset: asset, track: track, size: natural, transform: transform, end: range.end)
        PerfCounters.backgroundReadBegan()
        let written = await MediaReadQueue.run(on: MediaReadQueue.alpha) { job.write(to: target) }
        PerfCounters.backgroundReadEnded()
        return written ? target : nil
    }

    /// 转一份要的东西（在 async 里加载好；阻塞的那一段只读和写）。
    private struct Job: @unchecked Sendable {
        let kind: Kind
        let asset: AVAsset
        let track: AVAssetTrack
        let size: CGSize
        let transform: CGAffineTransform
        let end: CMTime

        /// **只在 MediaReadQueue.alpha 上调。** 写到同目录的临时文件，全写完才挪成 `target`（半截文件不会被当成副本）。
        func write(to target: URL) -> Bool {
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)-\(target.lastPathComponent)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let reader = try? AVAssetReader(asset: asset),
                  let writer = try? AVAssetWriter(outputURL: temporary, fileType: .mov) else { return false }
            // 读成 BGRA：解码器给的就是文件里存的值（直通的不替你预乘，2026-11-16 实测）。逐帧要改像素，拿拷贝。
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            // 先解出第一帧：副本的颜色标记照抄解码器给它标的（见 `colorProperties`），编码器才知道该怎么把 BGRA 换回去。
            guard reader.startReading(), let first = output.copyNextSampleBuffer() else { return false }
            let width = Int(size.width.rounded()), height = Int(size.height.rounded())
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: kind == .premultiplied ? AVVideoCodecType.proRes4444 : AVVideoCodecType.proRes422,
                AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: colorProperties(of: first),
            ])
            input.expectsMediaDataInRealTime = false
            input.transform = transform  // 旋转矩阵照抄：副本的几何（裁切、摆放的换算）和原片一样
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
            guard writer.canAdd(input) else {
                reader.cancelReading()
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                reader.cancelReading()
                return false
            }
            // 会话从 0 起、时间戳逐帧照抄：副本的第几秒就是原片的第几秒。
            writer.startSession(atSourceTime: .zero)
            var frames = 0
            var next: CMSampleBuffer? = first
            while let sample = next {
                next = output.copyNextSampleBuffer()
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                guard let frame = converted(pixels, pool: adaptor.pixelBufferPool), waitUntilReady(input, writer) else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    return false
                }
                guard adaptor.append(frame, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    return false
                }
                frames += 1
            }
            guard reader.status == .completed, frames > 0 else {
                writer.cancelWriting()
                return false
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: end)  // 最后一帧撑到原片画面轨的结尾：副本的轨和原片一样长
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { return false }
            try? FileManager.default.removeItem(at: target)
            return (try? FileManager.default.moveItem(at: temporary, to: target)) != nil
        }

        /// 颜色标记。预乘副本照抄解码器给第一帧标的：原片没写标记时那是解码器猜的（320×180 这种小尺寸猜 SMPTE-C / 601），
        /// 照抄才和预览直接放原片时同一套换算（写死 709 的话饱和色差 10 级，2026-11-16 自检撞出来的）。遮罩是数据（灰度 = alpha），
        /// 新开的那块没有标记，一律 709、不许被换算。
        private func colorProperties(of sample: CMSampleBuffer) -> [String: String] {
            let pixels = kind == .premultiplied ? CMSampleBufferGetImageBuffer(sample) : nil
            func tag(_ key: CFString, _ fallback: String) -> String {
                pixels.flatMap { CVBufferCopyAttachment($0, key, nil) as? String } ?? fallback
            }
            return [
                AVVideoColorPrimariesKey: tag(kCVImageBufferColorPrimariesKey, AVVideoColorPrimaries_ITU_R_709_2),
                AVVideoTransferFunctionKey: tag(kCVImageBufferTransferFunctionKey, AVVideoTransferFunction_ITU_R_709_2),
                AVVideoYCbCrMatrixKey: tag(kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrix_ITU_R_709_2),
            ]
        }

        /// 编码器吃不下就等一小会儿；writer 已经失败了就别等了。
        private func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) -> Bool {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waited < 10_000 else { return false }
                usleep(1000)
                waited += 1
            }
            return true
        }

        /// 一帧换算。预乘副本：在读出来的那块上原地预乘（它是拷贝，归我们），标明预乘（写进文件的 `almo`）。
        /// 遮罩：新开一块，每个像素 (a, a, a, 不透明)。
        private func converted(_ pixels: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
            guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
            switch kind {
            case .premultiplied:
                CVPixelBufferLockBaseAddress(pixels, [])
                defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
                guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
                var buffer = vImage_Buffer(
                    data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pixels)),
                    width: vImagePixelCount(CVPixelBufferGetWidth(pixels)), rowBytes: CVPixelBufferGetBytesPerRow(pixels)
                )
                // BGRA 的第四个通道是 alpha：vImage 的 RGBA8888 只认「alpha 在最后」，前三个通道乘它。
                guard vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
                CVBufferSetAttachment(
                    pixels, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate
                )
                return pixels
            case .matte:
                var made: CVPixelBuffer?
                guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let matte = made else { return nil }
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                CVPixelBufferLockBaseAddress(matte, [])
                defer {
                    CVPixelBufferUnlockBaseAddress(matte, [])
                    CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
                }
                guard let from = CVPixelBufferGetBaseAddress(pixels), let to = CVPixelBufferGetBaseAddress(matte) else { return nil }
                let fromRow = CVPixelBufferGetBytesPerRow(pixels), toRow = CVPixelBufferGetBytesPerRow(matte)
                let width = min(CVPixelBufferGetWidth(pixels), CVPixelBufferGetWidth(matte))
                let height = min(CVPixelBufferGetHeight(pixels), CVPixelBufferGetHeight(matte))
                for y in 0..<height {
                    let source = from.advanced(by: y * fromRow).assumingMemoryBound(to: UInt8.self)
                    let target = to.advanced(by: y * toRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let alpha = source[x * 4 + 3]
                        target[x * 4] = alpha
                        target[x * 4 + 1] = alpha
                        target[x * 4 + 2] = alpha
                        target[x * 4 + 3] = 255
                    }
                }
                return matte
            }
        }
    }

    /// 同一份副本同时只转一次：后来的等先来的那一趟（预览重建、AI 的 look、预渲染可能同时要同一份）。
    private actor Flights {
        static let shared = Flights()
        private var running: [URL: Task<URL?, Never>] = [:]

        func run(_ target: URL, _ work: @escaping @Sendable () async -> URL?) async -> URL? {
            if let task = running[target] { return await task.value }
            let task = Task { await work() }
            running[target] = task
            let result = await task.value
            running[target] = nil
            return result
        }
    }
}

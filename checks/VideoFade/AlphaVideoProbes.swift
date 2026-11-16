import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

// **带透明的视频那一组的素材和探针**（用例在 AlphaVideo.swift）：AVFoundation 现做带透明的视频和纯色底，按两条管线各自的解码器
// 读出四条带的参考色，预览（生产 builder 出的帧，不做色彩管理）和成片（rgb24）在给定的点上的码值。
// 管什么：只做素材、只读数；不管场景怎么搭、断言怎么写。从 AlphaVideo.swift 拆出来（单文件 400 行的目标）。

/// 现做一段带透明的视频。`tag` = 写不写预乘 / 直通的标记（只有 ProRes 能不写；HEVC 的编码器总会写）。
/// 写不出来（这台机器的 VideoToolbox 没有 HEVC 带透明的编码器）是 nil。
func makeAlphaVideo(_ name: String, codec: AVVideoCodecType, premultiplied: Bool, tag: Bool) async -> URL? {
    let url = root.appendingPathComponent(name)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
    var settings: [String: Any] = [
        AVVideoCodecKey: codec, AVVideoWidthKey: Int(alphaSize.width), AVVideoHeightKey: Int(alphaSize.height), AVVideoColorPropertiesKey: alphaColors,
    ]
    if codec == .hevcWithAlpha {
        let mode = premultiplied ? kVTAlphaChannelMode_PremultipliedAlpha : kVTAlphaChannelMode_StraightAlpha
        settings[AVVideoCompressionPropertiesKey] = [
            AVVideoQualityKey: 0.95, kVTCompressionPropertyKey_AlphaChannelMode as String: mode as String,
        ] as [String: Any]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(alphaSize.width), kCVPixelBufferHeightKey as String: Int(alphaSize.height),
    ])
    guard writer.canAdd(input) else { return nil }
    writer.add(input)
    guard writer.startWriting() else { return nil }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<20 {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
              let pixels = made else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<Int(alphaSize.height) {
            for x in 0..<Int(alphaSize.width) {
                let color = bandColors[min(3, x / 80)]
                let scale = premultiplied ? color[3] / 255 : 1
                let offset = y * row + x * 4
                base[offset] = UInt8((color[2] * scale).rounded())
                base[offset + 1] = UInt8((color[1] * scale).rounded())
                base[offset + 2] = UInt8((color[0] * scale).rounded())
                base[offset + 3] = UInt8(color[3])
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        if tag, codec != .hevcWithAlpha {
            CVBufferSetAttachment(pixels, kCVImageBufferAlphaChannelModeKey, premultiplied
                ? kCVImageBufferAlphaChannelMode_PremultipliedAlpha : kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        }
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else { return nil }
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed ? url : nil
}

/// 纯色的底（H.264，AVAssetWriter 写）。
func makeColorVideo(_ name: String, rgb: [UInt8], size: CGSize) async -> URL? {
    let url = root.appendingPathComponent(name)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoColorPropertiesKey: alphaColors,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(input)
    guard writer.startWriting() else { return nil }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<20 {
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 1_000_000) }
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
              let pixels = made else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: CVPixelBufferGetBytesPerRow(pixels) * Int(size.height), by: 4) {
            base[offset] = rgb[2]; base[offset + 1] = rgb[1]; base[offset + 2] = rgb[0]; base[offset + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed ? url : nil
}

func probedInfo(_ url: URL) async -> MediaInfo? {
    if case .success(let info) = await MediaProbe.probe(url: url, ffmpeg: nil) { return info }
    return nil
}

/// 这个文件第一帧四条带的中心，AVFoundation 解出来的（BGRA → [r, g, b, a]）：预览那一边的参考。
func readerBands(_ url: URL) async -> [[Double]]? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else { return nil }
    defer { reader.cancelReading() }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    return bandCenters.map { p in
        let o = Int(p.y) * row + Int(p.x) * 4
        return [Double(base[o + 2]), Double(base[o + 1]), Double(base[o]), Double(base[o + 3])]
    }
}

/// 同上，ffmpeg 解出来的（rgba）：成片那一边的参考。
func ffmpegBands(_ url: URL, name: String) -> [[Double]]? {
    let raw = root.appendingPathComponent("\(name)-decoded.rgba")
    let (code, out) = run(ffmpegPath, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-frames:v", "1",
                                       "-vf", "format=rgba", "-f", "rawvideo", "-pix_fmt", "rgba", raw.path])
    guard code == 0, let data = try? Data(contentsOf: raw), data.count >= Int(alphaSize.width * alphaSize.height) * 4 else {
        check(false, "\(name)：ffmpeg 解不出第一帧：\(out.suffix(300))")
        return nil
    }
    return bandCenters.map { p in
        let o = (Int(p.y) * Int(alphaSize.width) + Int(p.x)) * 4
        return (0..<4).map { Double(data[o + $0]) }
    }
}

/// 预乘过的带色：存直通的乘上 alpha。
func premultipliedBands(_ bands: [[Double]], stored: SourceAlpha) -> [[Double]] {
    bands.map { band in stored == .straight ? band.prefix(3).map { $0 * band[3] / 255 } + [band[3]] : band }
}

/// 预览这一帧在这些点上的码值（[r, g, b]）。**不做色彩管理**：按图自己的色彩空间读，和解码器、成片的码值同一把尺。
func previewCodes(_ state: TimelineState, points: [CGPoint], at seconds: Double, proxies: OptimizedMediaLookup = .none) async -> [[Double]]? {
    guard let built = await VideoEditCompositionBuilder.build(from: state, proxies: proxies) else { return nil }
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return points.map { p in
        let o = (Int(p.y) * image.width + Int(p.x)) * 4
        return [Double(data[o]), Double(data[o + 1]), Double(data[o + 2])]
    }
}

/// 成片这一帧在这些点上的码值（rgb24）。
func exportCodes(_ product: URL, points: [CGPoint], at seconds: Double, canvas: CGSize, name: String) -> [[Double]]? {
    let raw = root.appendingPathComponent("\(name)-frame.rgb")
    let (code, out) = run(ffmpegPath, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(seconds), "-i", product.path,
                                       "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path])
    guard code == 0, let data = try? Data(contentsOf: raw), data.count >= Int(canvas.width * canvas.height) * 3 else {
        check(false, "\(name)：成片抽不出帧：\(out.suffix(300))")
        return nil
    }
    return points.map { p in
        let o = (Int(p.y) * Int(canvas.width) + Int(p.x)) * 3
        return (0..<3).map { Double(data[o + $0]) }
    }
}

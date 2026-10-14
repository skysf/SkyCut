import AVFoundation
import CoreVideo
import Foundation

// look 读不出画面时说为什么（AIUnreadableVideo）：真写一段 H.264，再把文件里视频轨的「avc1」改成「hev1」
// （ffmpeg 封 HEVC 不点名时的写法，macOS 的视频框架不开）—— AVFoundation 照样报出 hev1、解不开，话里要说清是什么、
// 用 compress_videos 转一份。由来：docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md 第 3 条。
// 编法见 scripts/check-mcp.sh。

func runUnreadableVideoChecks() async {
    // 纯值：照事实说。
    let hev1 = AIUnreadableVideo.message(name: "a.mp4", facts: .init(exists: true, codec: "hev1", decodable: false))
    check(hev1.contains("'hev1'") && hev1.contains("'hvc1'") && hev1.contains("compress_videos"),
          "hev1: says what it is and how to get a copy SrtFlow can read: \(hev1)")
    let other = AIUnreadableVideo.message(name: "a.mp4", facts: .init(exists: true, codec: "vp09", decodable: false))
    check(other.contains("cannot decode") && other.contains("'vp09'") && other.contains("compress_videos"), "another codec: \(other)")
    check(AIUnreadableVideo.message(name: "a.mp4", facts: .init(exists: false)).contains("not there"), "a missing file says so")
    check(!AIUnreadableVideo.message(name: "a.mp4", facts: .init(exists: true, codec: "avc1", decodable: true)).contains("compress_videos"),
          "a file this Mac can decode is not sent to compress_videos")

    // 真文件：写一段 H.264 → 能读的没有毛病；把视频轨的 avc1 改成 hev1 → 报出 hev1、解不开。
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("srtflow-unreadable-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let readable = folder.appendingPathComponent("readable.mp4")
    guard await writeTinyH264(to: readable), let data = try? Data(contentsOf: readable),
          let patched = renamedSampleEntry(data, from: "avc1", to: "hev1") else {
        check(false, "could not make the test video")
        return
    }
    let unreadable = folder.appendingPathComponent("hev1.mp4")
    try? patched.write(to: unreadable)
    let good = await AIUnreadableVideo.facts(for: readable)
    checkEqual(good.codec, "avc1", "the readable file's video is avc1")
    checkEqual(await AIUnreadableVideo.problem(for: readable), nil, "a readable file has no problem to report")
    let bad = await AIUnreadableVideo.facts(for: unreadable)
    checkEqual(bad.codec, "hev1", "AVFoundation still reports the hev1 sample entry")
    checkEqual(bad.decodable, false, "…and cannot decode it")
    let said = await AIUnreadableVideo.reason(for: unreadable)
    check(said.contains("hev1.mp4") && said.contains("'hev1'") && said.contains("compress_videos"), "the reason the AI gets: \(said)")
    check(await AIUnreadableVideo.problem(for: folder.appendingPathComponent("gone.mp4"))?.contains("not there") == true,
          "a file that is gone is reported as gone")
}

/// 写 10 帧 64×64 的 H.264（AVAssetWriter，不依赖 ffmpeg）。
private func writeTinyH264(to url: URL) async -> Bool {
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64
    ])
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<10 {
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 20), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed
}

/// 把 stsd 里第一个 `from` 样本描述的四个字符换成 `to`（只动视频轨的那一处，ftyp 里的品牌不碰）。
private func renamedSampleEntry(_ data: Data, from: String, to: String) -> Data? {
    let bytes = [UInt8](data)
    let stsd = Array("stsd".utf8), old = Array(from.utf8), new = Array(to.utf8)
    guard let box = firstIndex(of: stsd, in: bytes, from: 0), let entry = firstIndex(of: old, in: bytes, from: box) else { return nil }
    var patched = bytes
    patched.replaceSubrange(entry..<(entry + 4), with: new)
    return Data(patched)
}

private func firstIndex(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
    guard bytes.count >= needle.count else { return nil }
    return (start...(bytes.count - needle.count)).first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
}

import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// **A transparent still is one encoded frame shared by 120 samples** (2026-11-17, MCP-76,
// docs/bugfixes/2026-11-17-alpha-media-waits-and-oversized-stills.md). ProRes 4444 is intra-only, so the old conversion (decode
// once, `loop` 119 copies) still stored the picture 120 times: a 1080p title was 107–441 MB and took 3.5–5.6 s, a 96-frame PNG
// sequence about 10 GB. Now the production arguments encode one frame lasting the whole still and `StillFrameSharing` points
// 120 samples of 0.5 s at it. Checked on the production arguments and the production rewrite:
// - the encoder writes one frame; after sharing the track is 120 frames at 2 fps over 60 s, for ffmpeg and for AVFoundation;
// - it is the same movie as writing every frame (`everyFrame: true`, the fallback): export-style trims through ffmpeg give
//   identical frames (framemd5), AVFoundation decodes identical pixels at identical times — only the size differs;
// - the file stays about one frame big;
// - layouts the rewrite does not know (already shared, every frame written, H.264, moov in front, cut off, a count that does
//   not divide the duration) throw `Unsupported` and leave the file byte for byte as it was.
// The image is drawn with CoreGraphics (not made by the ffmpeg under test). Build: scripts/check-still-clip-encode.sh.

/// 640×360, a colour gradient whose alpha ramps from 0 on the left to 255 on the right: every pixel differs, so a ProRes frame
/// is not trivially small and a mix-up between frames would show.
private func drawRamp(_ name: String) -> URL {
    let url = root.appendingPathComponent(name)
    let width = 640, height = 360
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let alpha = Double(x) / Double(width - 1)
            let i = (y * width + x) * 4
            pixels[i] = UInt8(Double(x * 255 / width) * alpha)  // premultiplied RGBA for CGContext
            pixels[i + 1] = UInt8(Double(y * 255 / height) * alpha)
            pixels[i + 2] = UInt8(160 * alpha)
            pixels[i + 3] = UInt8(255 * alpha)
        }
    }
    let image = pixels.withUnsafeMutableBytes { buffer -> CGImage in
        CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }
    let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, image, nil)
    _ = CGImageDestinationFinalize(sink)
    return url
}

private func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
}

/// ffmpeg's frame checksums after an export-style trim (`trim`, `setpts`, `fps`): what the export graph reads from the still.
private func trimmedFrames(_ url: URL, start: Double, end: Double, name: String) -> [String] {
    let out = root.appendingPathComponent("\(name).framemd5")
    let (code, output) = run(ffmpegPath, [
        "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", url.path,
        "-filter_complex", "[0:v]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS,fps=30,format=rgba",
        "-f", "framemd5", out.path,
    ])
    guard code == 0, let text = try? String(contentsOf: out, encoding: .utf8) else { return ["error: \(output.suffix(200))"] }
    // Keep pts, duration and hash (drop the stream index and size columns' spacing differences).
    return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
        line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.dropFirst().joined(separator: ",")
    }
}

/// What AVFoundation sees: duration, nominal rate, minimum frame duration, and every decoded frame's time + pixel digest.
private struct Decoded: Equatable {
    var duration = 0.0
    var nominalRate: Float = 0
    var minFrame = 0.0
    var frames: [String] = []
}

private func decoded(_ url: URL) async -> Decoded? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let (range, rate, minFrame) = try? await track.load(.timeRange, .nominalFrameRate, .minFrameDuration),
          let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    guard reader.startReading() else { return nil }
    var result = Decoded(duration: range.duration.seconds, nominalRate: rate, minFrame: minFrame.seconds)
    while let sample = output.copyNextSampleBuffer() {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let bytes = Data(bytes: CVPixelBufferGetBaseAddress(pixels)!,
                         count: CVPixelBufferGetHeight(pixels) * CVPixelBufferGetBytesPerRow(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        result.frames.append("\(time):" + SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined())
    }
    return reader.status == .completed ? result : nil
}

/// The rewrite refuses this file and leaves it exactly as it was.
private func expectRefused(_ url: URL, count: Int = StillImageClipFactory.stillFrameCount, _ label: String) {
    let before = try? Data(contentsOf: url)
    do {
        try StillFrameSharing.shareSingleFrame(in: url, count: count)
        check(false, "\(label): the rewrite should refuse it")
    } catch let refused as StillFrameSharing.Unsupported {
        check(before != nil && (try? Data(contentsOf: url)) == before, "\(label): refused (\(refused)) and left untouched")
    } catch {
        check(false, "\(label): refused with an unexpected error \(error)")
    }
}

func checkSharedFrameStills() async {
    let image = drawRamp("ramp.png")
    let frames = StillImageClipFactory.stillFrameCount
    // The production arguments: one encoded frame lasting the whole still.
    let single = root.appendingPathComponent("ramp-single.mov")
    let (singleCode, singleOut) = run(ffmpegPath, StillImageClipFactory.alphaConversionArguments(
        image: image, output: single, nativeResolution: false
    ))
    check(singleCode == 0, "single-frame encode failed: \(singleOut.suffix(300))")
    check(frameCount(single) == 1, "the encoder writes one frame, not \(frames) (measured \(frameCount(single)))")
    let singleSize = fileSize(single)

    // The fallback / old layout: every frame written.
    let every = root.appendingPathComponent("ramp-every.mov")
    let (everyCode, everyOut) = run(ffmpegPath, StillImageClipFactory.alphaConversionArguments(
        image: image, output: every, nativeResolution: false, everyFrame: true
    ))
    check(everyCode == 0, "every-frame encode failed: \(everyOut.suffix(300))")
    check(frameCount(every) == frames, "the fallback writes all \(frames) frames (measured \(frameCount(every)))")

    // Refusals on files the rewrite must not touch (copies, so the originals stay usable below).
    let copies = ["every", "fast-start", "cut"].map { root.appendingPathComponent("refuse-\($0).mov") }
    try? FileManager.default.copyItem(at: every, to: copies[0])
    expectRefused(copies[0], "every frame written (\(frames) samples)")
    let (fastCode, _) = run(ffmpegPath, ["-hide_banner", "-loglevel", "error", "-y", "-i", single.path, "-c", "copy",
                                         "-movflags", "+faststart", copies[1].path])
    if fastCode == 0 { expectRefused(copies[1], "moov in front of mdat") } else { check(false, "could not make the fast-start copy") }
    if let head = try? Data(contentsOf: single).prefix(2_000) { try? head.write(to: copies[2]) }
    expectRefused(copies[2], "cut-off file")
    let odd = root.appendingPathComponent("refuse-odd.mov")
    try? FileManager.default.copyItem(at: single, to: odd)
    expectRefused(odd, count: 7, "a sample count that does not divide the duration")
    let matte = root.appendingPathComponent("ramp-matte.mp4")
    if run(ffmpegPath, StillImageClipFactory.matteConversionArguments(image: image, output: matte, nativeResolution: false)).0 == 0 {
        expectRefused(matte, "the H.264 matte")
    } else {
        check(false, "could not make the matte")
    }

    // Share the single frame (the production rewrite), then compare with every frame written.
    let shared = root.appendingPathComponent("ramp-shared.mov")
    try? FileManager.default.copyItem(at: single, to: shared)
    do {
        try StillFrameSharing.shareSingleFrame(in: shared, count: frames)
    } catch {
        check(false, "the rewrite refused ffmpeg's own single-frame movie: \(error)")
        return
    }
    expectRefused(shared, "already shared (a second rewrite)")
    check(frameCount(shared) == frames, "after sharing ffmpeg reads \(frames) frames (measured \(frameCount(shared)))")
    check(fileSize(shared) <= singleSize + 4_096, "shared file stays one frame big: \(fileSize(shared)) bytes vs one frame \(singleSize)")
    check(fileSize(every) >= 50 * fileSize(shared),
          "writing every frame is the 120× file the sharing avoids: \(fileSize(every)) vs \(fileSize(shared)) bytes")
    print("shared-frame still 640×360: one frame \(singleSize) B, shared \(fileSize(shared)) B, every frame \(fileSize(every)) B")

    for (start, end) in [(0.0, 5.0), (12.3, 17.3), (55.2, 60.0), (0.2, 0.4), (30.0, 30.1), (59.9, 60.0)] {
        let a = trimmedFrames(shared, start: start, end: end, name: "shared-\(start)")
        let b = trimmedFrames(every, start: start, end: end, name: "every-\(start)")
        check(a == b, "export-style trim \(start)–\(end) s: same frames as every frame written (\(a.count) vs \(b.count))")
    }
    if let sharedFrames = await decoded(shared), let everyFrames = await decoded(every) {
        check(sharedFrames.frames.count == frames, "AVFoundation decodes \(frames) frames from the shared file (\(sharedFrames.frames.count))")
        check(abs(sharedFrames.duration - StillImageClipFactory.stillDuration) < 0.001 && sharedFrames.nominalRate == 2
              && abs(sharedFrames.minFrame - 0.5) < 0.001,
              "AVFoundation: 60 s at 2 fps, 0.5 s frames (\(sharedFrames.duration) s, \(sharedFrames.nominalRate) fps, \(sharedFrames.minFrame) s)")
        check(sharedFrames == everyFrames, "AVFoundation: same times and pixels as every frame written")
    } else {
        check(false, "AVFoundation could not read the shared or the every-frame file")
    }

    // The factory end to end: a transparent PNG lands as a shared-frame still (with its matte), several at once.
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
    let ffmpeg = URL(fileURLWithPath: ffmpegPath)
    let images = (0..<6).map { index -> URL in
        let copy = root.appendingPathComponent("ramp-\(index).png")
        try? FileManager.default.copyItem(at: image, to: copy)
        return copy
    }
    let made = await withTaskGroup(of: URL?.self) { group -> [URL] in
        for copy in images { group.addTask { try? await StillImageClipFactory.stillVideo(for: copy, ffmpeg: ffmpeg) } }
        var urls: [URL] = []
        for await url in group { if let url { urls.append(url) } }
        return urls
    }
    check(made.count == images.count, "six transparent stills converted at once: \(made.count) landed")
    for still in made {
        check(StillAlphaNaming.isAlphaStill(still) && fileSize(still) <= singleSize + 4_096 && frameCount(still) == frames,
              "factory still \(still.lastPathComponent): shared frame (\(fileSize(still)) B, \(frameCount(still)) frames)")
        try? FileManager.default.removeItem(at: StillAlphaNaming.matteURL(forStill: still))
        try? FileManager.default.removeItem(at: still)
    }
}

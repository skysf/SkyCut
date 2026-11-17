import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// **The launch rewrite of old every-frame transparent stills** (StillCacheSweep, 2026-11-17): only old-format files, only in the
// cache folder, and what it writes decodes exactly as before. In a scratch folder standing in for
// ~/Library/Caches/SrtFlow/StillClips/ (never the app's own cache):
// - old stills (every frame written by the old arguments, `everyFrame: true`) in the three ways ffmpeg chunks them — all 120
//   samples in one chunk, several per chunk, one per chunk (frames over about half a MiB) — are rewritten to one frame: about one
//   frame big, the same as a new shared-frame still of the same picture, and the same frames for ffmpeg (export-style trims) and
//   AVFoundation (times and pixels) as before; the next sweep leaves them alone;
// - left byte for byte as they were: a new shared-frame still, the old file under names the factory does not give (user-like,
//   `.bak`, an upper-case key, an opaque `-v3.mp4`), a matte, one in a subfolder, a symbolic link to an old file outside the
//   folder (and that file), one whose last frame differs, a cut-off one.
// Images are drawn with CoreGraphics (not made by the ffmpeg under test). Build: scripts/check-still-clip-encode.sh.

/// Seeded noise with an alpha ramp (premultiplied RGBA): converts as a transparent still, compresses badly, so the frame size —
/// and with it how ffmpeg chunks the 120 copies — follows the image size.
private func drawNoise(_ name: String, width: Int, height: Int) -> URL {
    let url = root.appendingPathComponent(name)
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let alpha = Double(x + 1) / Double(width)
            let i = (y * width + x) * 4
            for channel in 0..<3 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                pixels[i + channel] = UInt8(Double(state >> 56) * alpha)
            }
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

private func digest(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "unreadable" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A still converted with the production arguments: the old way (every frame) or the new one (one frame, shared).
private func convert(_ image: URL, to output: URL, everyFrame: Bool) -> Bool {
    let (code, out) = run(ffmpegPath, StillImageClipFactory.alphaConversionArguments(
        image: image, output: output, nativeResolution: false, everyFrame: everyFrame
    ))
    guard code == 0 else {
        check(false, "\(output.lastPathComponent): conversion failed: \(out.suffix(300))")
        return false
    }
    if everyFrame { return true }
    do {
        try StillFrameSharing.shareSingleFrame(in: output, count: StillImageClipFactory.stillFrameCount)
        return true
    } catch {
        check(false, "\(output.lastPathComponent): sharing failed: \(error)")
        return false
    }
}

/// How many samples ffmpeg put in each chunk (the first stsc run). The moov is last: search from the end, noise in mdat could
/// spell "stsc" too.
private func samplesPerChunk(_ url: URL) -> Int {
    guard let data = try? Data(contentsOf: url), let type = data.range(of: Data("stsc".utf8), options: .backwards) else { return -1 }
    let at = type.lowerBound + 4 + 12  // version/flags, entry count, first chunk, then samples per chunk
    return Int(data[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
}

/// Where the last stored frame starts and how long it is (the reader the sweep uses).
private func lastFrame(_ url: URL) -> Range<Int>? {
    guard let file = try? Data(contentsOf: url), let layout = try? StillMovieLayout(file: file),
          let samples = try? layout.samples(count: StillImageClipFactory.stillFrameCount), let last = samples.offsets.last
    else { return nil }
    return last..<(last + samples.size)
}

func checkStillCacheSweep() async {
    let frames = StillImageClipFactory.stillFrameCount
    let folder = root.appendingPathComponent("StillClips", isDirectory: true)
    let outside = root.appendingPathComponent("Movies", isDirectory: true)
    for directory in [folder, folder.appendingPathComponent("sub"), outside] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func key(_ n: Int) -> String { String(repeating: String(format: "%x", n % 16), count: 32) }

    // ---- Old stills in the three chunk layouts, and the new still of each picture to compare with ----
    let shapes: [(label: String, width: Int, height: Int, native: Bool)] = [
        ("one chunk", 32, 18, false), ("several per chunk", 160, 90, true), ("one per chunk", 448, 256, false),
    ]
    var old: [(name: String, label: String, copy: URL, shared: URL)] = []
    for (index, shape) in shapes.enumerated() {
        let image = drawNoise("sweep-\(index).png", width: shape.width, height: shape.height)
        let name = StillAlphaNaming.stillName(key: key(index + 1), nativeResolution: shape.native)
        let copy = root.appendingPathComponent("before-\(index).mov")
        let shared = root.appendingPathComponent("shared-\(index).mov")
        guard convert(image, to: folder.appendingPathComponent(name), everyFrame: true),
              convert(image, to: shared, everyFrame: false) else { return }
        if index < 2 { try? FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: copy) }
        old.append((name, shape.label, copy, shared))
    }
    let chunking = old.map { samplesPerChunk(folder.appendingPathComponent($0.name)) }
    check(chunking[0] == frames && chunking[1] > 1 && chunking[1] < frames && chunking[2] == 1,
          "the old stills cover ffmpeg's three chunk layouts (samples in the first chunk: \(chunking))")

    // ---- Files the sweep must leave exactly as they are ----
    let tiny = folder.appendingPathComponent(old[0].name)
    var untouched: [URL] = []
    func place(_ url: URL, from source: URL) {
        try? FileManager.default.copyItem(at: source, to: url)
        untouched.append(url)
    }
    place(folder.appendingPathComponent(StillAlphaNaming.stillName(key: key(9), nativeResolution: false)), from: old[0].shared)
    place(folder.appendingPathComponent("holiday-alpha-v1.mov"), from: tiny)
    place(folder.appendingPathComponent(old[0].name + ".bak"), from: tiny)
    place(folder.appendingPathComponent(StillAlphaNaming.stillName(key: key(10).uppercased(), nativeResolution: false)), from: tiny)
    place(folder.appendingPathComponent("\(key(11))-v3.mp4"), from: tiny)
    place(folder.appendingPathComponent("sub/" + StillAlphaNaming.stillName(key: key(12), nativeResolution: false)), from: tiny)
    let userTake = outside.appendingPathComponent("take-alpha-v1.mov")
    place(userTake, from: tiny)
    let link = folder.appendingPathComponent(StillAlphaNaming.stillName(key: key(13), nativeResolution: false))
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: userTake)
    let matte = StillAlphaNaming.matteURL(forStill: tiny)
    let (matteCode, _) = run(ffmpegPath, StillImageClipFactory.matteConversionArguments(
        image: root.appendingPathComponent("sweep-0.png"), output: matte, nativeResolution: false
    ))
    check(matteCode == 0, "could not make the matte")
    untouched.append(matte)
    let differs = folder.appendingPathComponent(StillAlphaNaming.stillName(key: key(14), nativeResolution: false))
    if var data = try? Data(contentsOf: tiny), let last = lastFrame(tiny) {
        data[last.lowerBound + last.count / 2] ^= 0x01  // one bit in the middle of the last stored frame
        try? data.write(to: differs)
        untouched.append(differs)
    } else {
        check(false, "could not read the old still's last frame")
    }
    if let head = try? Data(contentsOf: tiny).prefix(2_000) {
        let cut = folder.appendingPathComponent(StillAlphaNaming.stillName(key: key(15), nativeResolution: false))
        try? head.write(to: cut)
        untouched.append(cut)
    }
    let before = untouched.map(digest)
    let sizesBefore = old.map { fileSize(folder.appendingPathComponent($0.name)) }

    // ---- Sweep ----
    let report = StillCacheSweep.sweep(directory: folder)
    check(report.compacted == old.map(\.name).sorted(), "the three old stills are rewritten, nothing else: \(report.compacted)")
    check(report.bytesBefore == Int64(sizesBefore.reduce(0, +)), "it reports what they took (\(report.bytesBefore) B)")
    print("still cache sweep: \(report.compacted.count) old stills \(report.bytesBefore) B → \(report.bytesAfter) B (freed \(report.freed) B)")
    check(untouched.map(digest) == before, "every other file is byte for byte as it was")
    let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    check(linkTarget == userTake.path, "the link is still a link to the file outside (\(linkTarget ?? "gone"))")
    check(report.skipped.keys.contains(differs.lastPathComponent)
          && report.skipped[differs.lastPathComponent]?.contains("same picture") == true,
          "a file whose frames differ is left alone and said so: \(report.skipped[differs.lastPathComponent] ?? "not listed")")

    for (index, entry) in old.enumerated() {
        let rewritten = folder.appendingPathComponent(entry.name)
        check(abs(fileSize(rewritten) - fileSize(entry.shared)) <= 1_024,
              "\(entry.label): one frame big like a new still (\(fileSize(rewritten)) vs \(fileSize(entry.shared)) B, was \(sizesBefore[index]) B)")
        check(frameCount(rewritten) == frames, "\(entry.label): ffmpeg still reads \(frames) frames (\(frameCount(rewritten)))")
        let reference = index < 2 ? entry.copy : entry.shared
        for (start, end) in [(0.0, 3.0), (29.9, 30.6), (59.6, 60.0)] {
            check(trimmedFrames(rewritten, start: start, end: end, name: "sweep-\(index)-\(start)")
                  == trimmedFrames(reference, start: start, end: end, name: "reference-\(index)-\(start)"),
                  "\(entry.label): export-style trim \(start)–\(end) s gives the same frames as \(index < 2 ? "before" : "a new still")")
        }
        let after = await decoded(rewritten), expected = await decoded(reference)
        check(after != nil && after == expected,
              "\(entry.label): AVFoundation decodes the same times and pixels (\(after?.frames.count ?? -1) frames)")
    }

    // ---- Once: the next sweep finds nothing to do ----
    let again = StillCacheSweep.sweep(directory: folder)
    check(again.compacted.isEmpty && again.skipped == report.skipped, "a second sweep rewrites nothing: \(again.compacted)")
    for directory in [folder, outside] { try? FileManager.default.removeItem(at: directory) }
}

import AVFoundation
import Foundation

// Reading a rendered movie back: frames decoded as BGRA, exactly as stored (premultiplied: the decoder does not
// convert), plus the alpha tag through SkyCut's own reader (`SourceAlpha`). Decoding blocks a thread, so it runs on a
// plain dispatch queue, never on a Swift-concurrency thread (docs/architecture/blocking-media-reads.md).

struct DecodedFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func pixel(x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    /// Largest and mean channel difference against another frame of the same size (BGRA, all four channels).
    func difference(to other: DecodedFrame) -> (maximum: Int, mean: Double) {
        guard other.pixels.count == pixels.count else { return (255, 255) }
        var maximum = 0
        var total = 0
        for i in pixels.indices {
            let d = abs(Int(pixels[i]) - Int(other.pixels[i]))
            maximum = max(maximum, d)
            total += d
        }
        return (maximum, Double(total) / Double(max(pixels.count, 1)))
    }

    /// The leftmost x in row y with alpha above `threshold`, or nil.
    func firstOpaqueX(row y: Int, threshold: Int = 128) -> Int? {
        (0..<width).first { pixel(x: $0, y: y).a > threshold }
    }
}

enum MovieFrames {
    /// Frames at the given indices (0-based, in decode order).
    static func decode(_ url: URL, frames wanted: Set<Int>) async -> [Int: DecodedFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let job = Job(asset: asset, track: track, wanted: wanted)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: job.read())
            }
        }
    }

    private struct Job: @unchecked Sendable {
        let asset: AVAsset
        let track: AVAssetTrack
        let wanted: Set<Int>

        func read() -> [Int: DecodedFrame] {
            MovieFrames.decodeBlocking(asset, track, frames: wanted)
        }
    }

    private static func decodeBlocking(_ asset: AVAsset, _ track: AVAssetTrack, frames wanted: Set<Int>) -> [Int: DecodedFrame] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [:] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { return [:] }
        var frames: [Int: DecodedFrame] = [:]
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard wanted.contains(index), let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                for y in 0..<height {
                    pixels.withUnsafeMutableBytes { target in
                        target.baseAddress!.advanced(by: y * width * 4).copyMemory(from: base.advanced(by: y * row), byteCount: width * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames[index] = DecodedFrame(width: width, height: height, pixels: pixels)
        }
        reader.cancelReading()
        return frames
    }

    /// How SkyCut reads the file's alpha (the production rule, MediaProbe.swift).
    static func alphaTag(_ url: URL) async -> SourceAlpha? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        return SourceAlpha(format: format)
    }

    static func frameCount(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange), let rate = try? await track.load(.nominalFrameRate) else { return -1 }
        return Int((range.duration.seconds * Double(rate)).rounded())
    }
}

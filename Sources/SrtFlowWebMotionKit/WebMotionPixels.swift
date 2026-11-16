import CryptoKit
import Foundation

// MARK: - Pixel rules for rendered frames (pure)
//
// Owns: what a frame is in memory (8-bit BGRA, premultiplied, sRGB: exactly what WebKit's snapshot gives and what
// `kCVPixelFormatType_32BGRA` stores), "is this frame empty", the frame digest the "same t twice" check compares, and the
// public-API way of getting alpha (one frame drawn over black and over white). Does not own: taking snapshots or encoding
// (the helper). docs/architecture/web-motion-renderer.md「透明背景」.

/// A view of one frame's pixels: `height` rows of `width` BGRA pixels, `bytesPerRow` apart (rows may be padded).
public struct WebMotionFrameBytes {
    public let base: UnsafeRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    func row(_ y: Int) -> UnsafePointer<UInt8> {
        base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
    }

    /// The premultiplied BGRA bytes of pixel (x, y), y from the top.
    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let p = row(y).advanced(by: x * 4)
        return (p[0], p[1], p[2], p[3])
    }
}

public enum WebMotionPixels {
    /// True when every pixel is fully transparent (alpha 0).
    public static func isBlank(_ frame: WebMotionFrameBytes) -> Bool {
        for y in 0..<frame.height {
            let row = frame.row(y)
            var x = 3
            let end = frame.width * 4
            while x < end {
                if row[x] != 0 { return false }
                x += 4
            }
        }
        return true
    }

    /// SHA-256 of the visible bytes, row by row (padding excluded), as lowercase hex.
    public static func digest(_ frame: WebMotionFrameBytes) -> String {
        var hasher = SHA256()
        let rowBytes = frame.width * 4
        for y in 0..<frame.height {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: frame.row(y), count: rowBytes))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The public way to get alpha: the same frame drawn over opaque black and over opaque white. WebKit blends in 8-bit
    /// sRGB values: over black B = a·c, over white W = a·c + (1 − a)·255, so 1 − a = (W − B) / 255 and the premultiplied
    /// color is B. Alpha comes from the mean difference of the three channels; the color is clamped to it (premultiplied
    /// colors never exceed alpha). Writes premultiplied BGRA with alpha over `black` in place.
    /// Pages must not depend on what is behind them (`mix-blend-mode` against the background breaks the derivation).
    public static func deriveAlpha(black: UnsafeMutableRawPointer, white: WebMotionFrameBytes) {
        for y in 0..<white.height {
            let b = black.advanced(by: y * white.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let w = white.row(y)
            for x in 0..<white.width {
                let i = x * 4
                let difference = (Int(w[i]) - Int(b[i])) + (Int(w[i + 1]) - Int(b[i + 1])) + (Int(w[i + 2]) - Int(b[i + 2]))
                // round(255 − difference / 3) without floating point: (765 − difference) / 3, rounded half up.
                let alpha = UInt8(clamping: (3 * 255 - difference + 1) / 3)
                b[i] = min(b[i], alpha)
                b[i + 1] = min(b[i + 1], alpha)
                b[i + 2] = min(b[i + 2], alpha)
                b[i + 3] = alpha
            }
        }
    }
}

import CoreGraphics
import CoreVideo
import Foundation
import SrtFlowWebMotionKit

// MARK: - From snapshot to frame bytes
//
// Owns: copying a snapshot into premultiplied BGRA sRGB memory (a CVPixelBuffer for the movie, or scratch memory for
// the second draw of the "same t twice" check) and joining the public path's black and white snapshots into one frame
// with alpha (`WebMotionPixels.deriveAlpha`). WebKit's snapshot is already sRGB, premultiplied BGRA (measured on macOS
// 26.5): the copy changes no pixel; another layout would be converted by Core Graphics.
// Does not own: taking snapshots (`PageWorker`), hashing / blank rules (`WebMotionPixels`).

/// What one frame came back as: one snapshot (fast path) or the same frame over black and over white (public path).
enum CapturedFrame {
    case single(CGImage)
    case pair(black: CGImage, white: CGImage)
}

/// Owned memory for one frame's pixels.
final class FrameMemory {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let base: UnsafeMutableRawPointer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        base = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
    }

    deinit { base.deallocate() }

    var bytes: WebMotionFrameBytes {
        WebMotionFrameBytes(base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow)
    }
}

enum FrameCapture {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes the frame into `base` (premultiplied BGRA, `bytesPerRow` apart); `scratch` holds the white snapshot of a
    /// pair. Returns the frame's bytes for hashing and the blank check.
    static func write(_ frame: CapturedFrame, into base: UnsafeMutableRawPointer, bytesPerRow: Int,
                      scratch: FrameMemory) throws -> WebMotionFrameBytes {
        switch frame {
        case .single(let image):
            try copy(image, into: base, bytesPerRow: bytesPerRow)
            return WebMotionFrameBytes(base: UnsafeRawPointer(base), width: image.width, height: image.height, bytesPerRow: bytesPerRow)
        case .pair(let black, let white):
            try copy(black, into: base, bytesPerRow: bytesPerRow)
            try copy(white, into: scratch.base, bytesPerRow: scratch.bytesPerRow)
            let whiteBytes = scratch.bytes
            guard whiteBytes.bytesPerRow == bytesPerRow else {
                throw Failure(description: "The black and white snapshots have different row sizes.")
            }
            WebMotionPixels.deriveAlpha(black: base, white: whiteBytes)
            return WebMotionFrameBytes(base: UnsafeRawPointer(base), width: black.width, height: black.height, bytesPerRow: bytesPerRow)
        }
    }

    /// Writes into a pixel buffer from the movie's pool.
    static func write(_ frame: CapturedFrame, into buffer: CVPixelBuffer, scratch: FrameMemory) throws -> (hash: String, blank: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(description: "A frame buffer has no memory.") }
        let bytes = try write(frame, into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), scratch: scratch)
        return (WebMotionPixels.digest(bytes), WebMotionPixels.isBlank(bytes))
    }

    private static func copy(_ image: CGImage, into base: UnsafeMutableRawPointer, bytesPerRow: Int) throws {
        guard let colorSpace,
              let context = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw Failure(description: "No drawing context for a \(image.width)×\(image.height) frame.")
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

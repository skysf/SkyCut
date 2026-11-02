import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 独立像素尺：从源帧按完整区域 contain / cover 算期望采样点，再量生产 look / 预览 / 导出。
// 不读 AIFrameFit / ClipCrop / placement，避免把生产计算的错误也拷进期望值。
struct RegionPixels {
    let image: CGImage
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // 测试会保留几份源坐标图；先复制像素，不能让这些基准 CGImage 长期钉住 AVFoundation 的解码缓冲。
        guard let copy = context.makeImage(), let data = context.data else { throw CocoaError(.coderInvalidValue) }
        self.image = copy
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func rgb(x: Double, y: Double) -> [Double] {
        let column = min(max(Int(x), 0), image.width - 1)
        let row = min(max(Int(y), 0), image.height - 1)
        let at = (row * image.width + column) * 4
        return (0..<3).map { Double(bytes[at + $0]) / 255 }
    }

    func error(source: RegionPixels, region: CGRect, fill: Bool) -> Double {
        let w = Double(image.width), h = Double(image.height)
        let sw = Double(source.image.width), sh = Double(source.image.height)
        let left = floor(region.minX * sw + 1e-9), top = floor(region.minY * sh + 1e-9)
        let rw = ceil(region.maxX * sw - 1e-9) - left, rh = ceil(region.maxY * sh - 1e-9) - top
        let factor = fill ? max(w / rw, h / rh) : min(w / rw, h / rh)
        let dx = (w - rw * factor) / 2, dy = (h - rh * factor) / 2
        var errors: [Double] = []
        // 上方时刻标签仅在 look 的 JPEG 中，避开前 10%；其余网格仍覆盖边缘和空白处。
        for x in [0.03, 0.2, 0.5, 0.8, 0.97] {
            for y in [0.12, 0.3, 0.5, 0.7, 0.97] {
                let sourceX = (x * w - dx) / factor, sourceY = (y * h - dy) / factor
                let expected = sourceX < 0 || sourceY < 0 || sourceX >= rw || sourceY >= rh
                    ? [0.0, 0.0, 0.0] : source.rgb(x: left + sourceX, y: top + sourceY)
                let actual = rgb(x: x * w, y: y * h)
                // R/G 编码源坐标；B 是高频棋盘，插值 / 色度抽样会模糊边界，不拿它当几何门槛。
                let error = max(abs(actual[0] - expected[0]), abs(actual[1] - expected[1]))
                if error > 0.055 { print("PIXEL: output \(image.width)x\(image.height) at \(x),\(y), source \(left + sourceX),\(top + sourceY), actual \(actual), expected \(expected)") }
                errors.append(error)
            }
        }
        return errors.max() ?? 1
    }

    func difference(_ other: RegionPixels) -> Double {
        var sum = 0.0
        for x in [0.03, 0.2, 0.5, 0.8, 0.97] {
            for y in [0.12, 0.3, 0.5, 0.7, 0.97] {
                let a = rgb(x: x * Double(image.width), y: y * Double(image.height))
                let b = other.rgb(x: x * Double(other.image.width), y: y * Double(other.image.height))
                sum += (0..<3).map { abs(a[$0] - b[$0]) }.reduce(0, +) / 3
            }
        }
        return sum / 25
    }

    func save(_ url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func jpeg(_ data: Data) throws -> RegionPixels {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try RegionPixels(image)
    }
}

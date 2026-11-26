// 检查最终 TIFF 的两种像素表示和逻辑尺寸；不生成图稿、不操作 Finder。
import AppKit
import ImageIO

func require(_ value: Bool, _ message: String) {
    guard value else { fputs("✗ DMG background: \(message)\n", stderr); exit(1) }
}
let path = CommandLine.arguments[1]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = NSImage(contentsOfFile: path) else {
    fputs("✗ Cannot decode DMG background\n", stderr)
    exit(1)
}
require(CGImageSourceGetCount(source) == 2, "TIFF must have both 1x and 2x representations")
require(image.size == NSSize(width: 760, height: 510), "logical size must remain 760×510 points")
for (index, scale) in [1, 2].enumerated() {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
    require((properties[kCGImagePropertyPixelWidth] as? Int) == 760 * scale, "wrong pixel width")
    require((properties[kCGImagePropertyPixelHeight] as? Int) == 510 * scale, "wrong pixel height")
    require((properties[kCGImagePropertyDPIWidth] as? Double) == Double(72 * scale), "wrong horizontal DPI")
    require((properties[kCGImagePropertyDPIHeight] as? Double) == Double(72 * scale), "wrong vertical DPI")
}
// 确认 2x 确实画了同一张完整图，而不是只有 2 倍尺寸、图稿却溢出画布。
// 在两种表示的左上 wordmark 和中间箭头处都必须存在森林绿像素。
// So must the step 2 badge near the bottom: the whole canvas carries artwork, not just its top.
// The drag hint is probed only on its own ink (the arrow's shaft, the pointer's black), never on the faded
// copies of SkyCut's icon, so a new app icon needs no edit here.
for index in 0..<2 {
    let bitmap = NSBitmapImageRep(cgImage: CGImageSourceCreateImageAtIndex(source, index, nil)!)
    let scale = index + 1
    for (x, y) in [(440, 164), (55, 50), (44, 449)] {
        let color = bitmap.colorAt(x: x * scale, y: y * scale)!.usingColorSpace(.sRGB)!
        require(color.greenComponent < 0.4 && color.alphaComponent == 1, "artwork missing at \(x),\(y) in representation \(index)")
    }
    let pointer = bitmap.colorAt(x: 396 * scale, y: 174 * scale)!.usingColorSpace(.sRGB)!
    require(max(pointer.redComponent, pointer.greenComponent, pointer.blueComponent) < 0.15,
            "the drag hint's black pointer is missing at 396,174 in representation \(index)")
    // Finder puts a selected icon on a 144 pt grey square, with its label in a pill below it: both icons'
    // areas (x 128–272 and 488–632, y 92–258) must be plain paper, like the corner at (20, 20). Halos there
    // clashed with the selection until 2026-11-26.
    require(bitmap.bitsPerSample == 8, "unexpected TIFF sample size")
    let data = bitmap.bitmapData!, step = bitmap.bitsPerPixel / 8, row = bitmap.bytesPerRow
    let paper = (0..<step).map { data[20 * scale * row + 20 * scale * step + $0] }
    for (left, right) in [(128, 272), (488, 632)] {
        for y in (92 * scale)..<(258 * scale) {
            for x in (left * scale)..<(right * scale) {
                let pixel = y * row + x * step
                if !(0..<step).allSatisfy({ abs(Int(data[pixel + $0]) - Int(paper[$0])) <= 1 }) {
                    require(false, "art under Finder's selection at \(x / scale),\(y / scale) in representation \(index)")
                }
            }
        }
    }
}
print("✓ Retina TIFF: 760×510 @72 dpi + 1520×1020 @144 dpi, complete opaque artwork, plain paper under the selection")

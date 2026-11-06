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
require(image.size == NSSize(width: 760, height: 560), "logical size must remain 760×560 points")
for (index, scale) in [1, 2].enumerated() {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
    require((properties[kCGImagePropertyPixelWidth] as? Int) == 760 * scale, "wrong pixel width")
    require((properties[kCGImagePropertyPixelHeight] as? Int) == 560 * scale, "wrong pixel height")
    require((properties[kCGImagePropertyDPIWidth] as? Double) == Double(72 * scale), "wrong horizontal DPI")
    require((properties[kCGImagePropertyDPIHeight] as? Double) == Double(72 * scale), "wrong vertical DPI")
}
// 确认 2x 确实画了同一张完整图，而不是只有 2 倍尺寸、图稿却溢出画布。
// 在两种表示的左上 wordmark 和中间箭头处都必须存在森林绿像素。
for index in 0..<2 {
    let bitmap = NSBitmapImageRep(cgImage: CGImageSourceCreateImageAtIndex(source, index, nil)!)
    let scale = index + 1
    for (x, y) in [(333, 164), (55, 50)] {
        let color = bitmap.colorAt(x: x * scale, y: y * scale)!.usingColorSpace(.sRGB)!
        require(color.greenComponent < 0.4 && color.alphaComponent == 1, "artwork missing at \(x),\(y) in representation \(index)")
    }
}
print("✓ Retina TIFF: 760×560 @72 dpi + 1520×1120 @144 dpi, complete opaque artwork")

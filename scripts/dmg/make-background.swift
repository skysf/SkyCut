// DMG 安装引导的唯一图稿：系统字体 + AppKit/Core Graphics，输出同一逻辑尺寸的 1x / 2x PNG。
// 不画 App / Applications 图标（那两个是 Finder 里能拖动的真实文件），不生成窗口布局。
import AppKit

let output = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : ""
guard !output.isEmpty else {
    fputs("Usage: swift scripts/dmg/make-background.swift <output-directory>\n", stderr)
    exit(2)
}
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let width = 760
let height = 560
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let paper = color(0xf3f0e8)
let forest = color(0x123f32)
let ink = color(0x19221d)
let secondary = color(0x505b4a)

// 下面全部用左上原点的 point 坐标；图片在深浅色模式下都使用自己的不透明底色。
func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, color: NSColor = ink) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
    ]
    let string = NSAttributedString(string: value, attributes: attributes)
    let bounds = string.size()
    precondition(x + bounds.width <= CGFloat(width) - 36, "DMG copy exceeds the canvas: \(value)")
    string.draw(at: NSPoint(x: x, y: CGFloat(height) - top - bounds.height))
}

func badge(_ number: Int, top: CGFloat) {
    forest.setFill()
    NSBezierPath(ovalIn: NSRect(x: 40, y: CGFloat(height) - top - 26, width: 26, height: 26)).fill()
    text("\(number)", x: 49, top: top + 3, size: 15, weight: .semibold, color: paper)
}

func artwork() {
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    text("SkyCut", x: 40, top: 28, size: 32, weight: .bold, color: forest)
    text("安装 / Install", x: 621, top: 43, size: 14, weight: .medium, color: forest)

    // 真实图标中心在 (200, 164)、(560, 164)，与模板的 Iloc 一致。
    color(0xe6e8dc).setFill()
    for centerX in [200, 560] {
        NSBezierPath(ovalIn: NSRect(x: centerX - 79, y: height - 164 - 79,
                                  width: 158, height: 158)).fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 321, y: height - 164))
    arrow.line(to: NSPoint(x: 439, y: height - 164))
    arrow.move(to: NSPoint(x: 423, y: height - 148))
    arrow.line(to: NSPoint(x: 439, y: height - 164))
    arrow.line(to: NSPoint(x: 423, y: height - 180))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    forest.setStroke()
    arrow.stroke()

    color(0xd7d5c8).setFill()
    NSRect(x: 40, y: height - 280, width: 680, height: 1).fill()
    badge(1, top: 305)
    text("把 SkyCut 拖到「应用程序」", x: 82, top: 304, size: 18, weight: .semibold)
    text("Drag SkyCut to Applications", x: 82, top: 334, size: 14, color: secondary)
    badge(2, top: 380)
    text("第一次打开被拦下：系统设置 › 隐私与安全性 › 仍要打开", x: 82, top: 379,
         size: 17, weight: .semibold)
    text("If macOS blocks it: System Settings › Privacy & Security › Open Anyway",
         x: 82, top: 409, size: 14, color: secondary)
    badge(3, top: 465)
    text("视频教程 / Video guide", x: 82, top: 464, size: 18, weight: .semibold)
    text("skycut.app/zh/docs · skycut.app/en/docs", x: 82, top: 494,
         size: 15, weight: .medium, color: forest)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
        pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    artwork()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/" + name))
    print("wrote \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(bitmap.size)")
}

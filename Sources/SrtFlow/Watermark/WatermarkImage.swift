import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 导出水印的那张图：Sky Studio 的 logo 画成 PNG
//
// 管什么：读 `Resources/watermark-logo.svg`（用户给的 logo，一条只有绝对坐标 M / L / Z 的路径、奇偶填充）成矢量路径，
// 再按要的宽现画一张透明底的 PNG：白字、一圈软阴影（亮画面上也看得清）、整体不透明度（`WatermarkPlacement.opacity`）。
// 路径是矢量，多大都清楚，不预先存位图。
// 不管什么：放哪、什么时候换（WatermarkPlacement）、怎么进滤镜图（WatermarkExport）、加不加（WatermarkPolicy）。
// 定的样子见收费方案第 11 条（docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md），约束见 docs/architecture/export-watermark.md。

enum WatermarkImage {
    static let resourceName = "watermark-logo.svg"

    /// logo 的形状：路径的原点挪到墨迹的左上角（y 向下，同 SVG），`size` 是墨迹的宽高（SVG 的单位）。
    struct Logo {
        let path: CGPath
        let size: CGSize
    }

    /// 读 SVG 里第一条路径的 `d`。只认绝对坐标的 M / L / Z（这份 logo 就是这样矢量化出来的）；有别的命令、没有路径、
    /// 墨迹是空的都回 nil —— 换 logo 时自检会先红，不会画出一张缺笔画的图。
    static func parse(svg: String) -> Logo? {
        guard let match = svg.range(of: #"<path\b[^>]*\sd="([^"]+)""#, options: .regularExpression) else { return nil }
        let element = String(svg[match])
        guard let open = element.range(of: #" d=""#)?.upperBound, let close = element[open...].firstIndex(of: "\"") else { return nil }
        let tokens = tokenize(element[open..<close])

        let path = CGMutablePath()
        var command: Character?
        var numbers: [CGFloat] = []
        func flush() -> Bool {
            guard let command else { return numbers.isEmpty }
            guard numbers.count.isMultiple(of: 2) else { return false }
            for index in stride(from: 0, to: numbers.count, by: 2) {
                let point = CGPoint(x: numbers[index], y: numbers[index + 1])
                // M 后面跟着的几对，第一对是起点、其余照 SVG 的规矩当成 L。
                if command == "M" && index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            numbers = []
            return true
        }
        for token in tokens {
            if let letter = token.first, letter.isLetter {
                guard flush() else { return nil }
                switch letter {
                case "M", "L": command = letter
                case "Z", "z": path.closeSubpath(); command = nil
                default: return nil
                }
            } else if let value = Double(token) {
                guard command != nil else { return nil }
                numbers.append(CGFloat(value))
            }
        }
        guard flush() else { return nil }

        let box = path.boundingBoxOfPath
        guard !path.isEmpty, box.width > 0, box.height > 0 else { return nil }
        var move = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        guard let moved = path.copy(using: &move) else { return nil }
        return Logo(path: moved, size: box.size)
    }

    /// 路径数据拆成命令字母和数字：逗号、空白分隔；`-` 开始一个新数（指数里的除外）。`e` / `E` 算数字的一部分（这里不认那两个命令）。
    static func tokenize(_ data: Substring) -> [String] {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number) }
            number = ""
        }
        for character in data {
            if character.isLetter, character != "e", character != "E" {
                flush()
                tokens.append(String(character))
            } else if character == "," || character.isWhitespace {
                flush()
            } else if character == "-", !number.isEmpty, number.last != "e", number.last != "E" {
                flush()
                number = "-"
            } else {
                number.append(character)
            }
        }
        flush()
        return tokens
    }

    /// App 资源里的那一份（AppResources）。
    static func load(from directories: [URL] = AppResources.directories) -> Logo? {
        guard let url = AppResources.url(named: resourceName, in: directories),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(svg: text)
    }

    /// 画出来的一张：PNG、整张图多大（像素）、墨迹离图的左上角多远（四周留给阴影的那一圈）。
    struct Rendered {
        let png: Data
        let pixelSize: CGSize
        let inset: CGFloat
        /// 墨迹的宽高（像素）。
        let inkSize: CGSize
    }

    /// 墨迹宽 `logoWidth` 像素。阴影：往右下偏宽的 1.2%、模糊半径宽的 4%、黑色 55%；整张图（字 + 阴影）再乘 `opacity`。
    static func render(_ logo: Logo, logoWidth: Int, opacity: Double) -> Rendered? {
        guard logoWidth > 0, logo.size.width > 0 else { return nil }
        let scale = CGFloat(logoWidth) / logo.size.width
        let ink = CGSize(width: CGFloat(logoWidth), height: (logo.size.height * scale).rounded(.up))
        let blur = max(2, ink.width * 0.04)
        let offset = max(1, (ink.width * 0.012).rounded())
        let inset = ceil(blur * 1.5 + offset)
        let width = Int(ink.width + inset * 2), height = Int(ink.height + inset * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setAlpha(CGFloat(opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // 位图的 y 向上、SVG 的 y 向下：先翻过来再按 SVG 的坐标画。阴影的偏移不跟着变换走（在设备空间里），往下是负的。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShadow(offset: CGSize(width: offset, height: -offset), blur: blur, color: CGColor(gray: 0, alpha: 0.55))
        context.translateBy(x: inset, y: inset)
        context.scaleBy(x: scale, y: scale)
        context.addPath(logo.path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath(using: .evenOdd)
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Rendered(png: data as Data, pixelSize: CGSize(width: width, height: height), inset: inset, inkSize: ink)
    }
}

import CoreGraphics
import Foundation
import ImageIO

// 纯值：logo 读得出、PNG 画得对、跳的表、四角 / 正中多大放哪、分段表达式（逐时刻求值和表一致、是平衡的）。

func runPureChecks(logo: WatermarkImage.Logo) {
    logoChecks(logo)
    imageChecks(logo)
    scheduleChecks()
    layoutChecks()
    piecewiseChecks()
}

private func logoChecks(_ logo: WatermarkImage.Logo) {
    // 用户给的 logo：墨迹从 (104.2, 360.5) 到 (1445.0, 1215.5)。
    check(abs(logo.size.width - 1340.8) < 0.5 && abs(logo.size.height - 855) < 0.5, "logo 的墨迹 1340.8 × 855：\(logo.size)")
    let box = logo.path.boundingBoxOfPath
    check(abs(box.minX) < 0.01 && abs(box.minY) < 0.01, "路径的原点挪到了墨迹的左上角：\(box.origin)")

    let square = WatermarkImage.parse(svg: ##"<svg><path fill="#fff" d="M10,20L30,20L30,40L10,40Z"/></svg>"##)
    check(square?.size == CGSize(width: 20, height: 20), "一个方块读成 20 × 20：\(String(describing: square?.size))")
    let implicit = WatermarkImage.parse(svg: #"<svg><path d="M0,0 10,0 10,5Z"/></svg>"#)
    check(implicit?.size == CGSize(width: 10, height: 5), "M 后面多给的几对当 L：\(String(describing: implicit?.size))")
    check(WatermarkImage.parse(svg: #"<svg><path d="M0,0C1,1 2,2 3,3Z"/></svg>"#) == nil, "曲线命令不认（读不全就不画，换 logo 时这里先红）")
    check(WatermarkImage.parse(svg: "<svg></svg>") == nil, "没有路径回 nil")
    check(WatermarkImage.parse(svg: #"<svg><path d="M5,5L5,5Z"/></svg>"#) == nil, "墨迹是空的回 nil")
    check(WatermarkImage.tokenize("M10-5L-3.5e1,2Z"[...]) == ["M", "10", "-5", "L", "-3.5e1", "2", "Z"],
          "紧挨着的负数拆开、指数里的负号不拆：\(WatermarkImage.tokenize("M10-5L-3.5e1,2Z"[...]))")
}

/// 解开 PNG，画进预乘的 RGBA 里读。
private func rgba(_ png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, bytes)
}

private func imageChecks(_ logo: WatermarkImage.Logo) {
    guard let image = WatermarkImage.render(logo, logoWidth: 270, opacity: 0.7), let pixels = rgba(image.png) else {
        check(false, "logo 画不出 PNG")
        return
    }
    check(image.inkSize == CGSize(width: 270, height: 173), "墨迹 270 宽、高按比例向上取整 173：\(image.inkSize)")
    check(image.pixelSize.width == 270 + image.inset * 2 && image.pixelSize.height == 173 + image.inset * 2,
          "整张图 = 墨迹四周各留一圈阴影：\(image.pixelSize)，留 \(image.inset)")
    check(pixels.width == Int(image.pixelSize.width) && pixels.height == Int(image.pixelSize.height), "PNG 的像素和报的一样大")
    var maxAlpha = 0, whitest = 0, darkShadow = 0
    for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
        let alpha = Int(pixels.bytes[index + 3]), red = Int(pixels.bytes[index])
        maxAlpha = max(maxAlpha, alpha)
        // 预乘的：原色 = 通道 × 255 / alpha。
        if alpha > 150 { whitest = max(whitest, red * 255 / alpha) }
        if alpha > 20 && alpha < 120 && red * 255 < 40 * alpha { darkShadow += 1 }
    }
    check(abs(maxAlpha - 178) <= 3, "整体不透明度 70%：最实的一点 alpha \(maxAlpha)，应约 178")
    check(whitest >= 250, "最实的地方是白字：原色 \(whitest)")
    check(darkShadow > 200, "字的四周有一圈黑的阴影：\(darkShadow) 个像素")
    check(pixels.bytes[3] == 0 && pixels.bytes[pixels.bytes.count - 1] == 0, "图的角落是透明的（阴影没出界）")
}

private func scheduleChecks() {
    let hour = WatermarkPlacement.schedule(total: 3600, seed: 7)
    check(hour.count == 900, "一小时 900 段：\(hour.count)")
    check(zip(hour, hour.dropFirst()).allSatisfy { $0.spot != $1.spot }, "不连续两次落在同一处")
    check(zip(hour, hour.dropFirst()).allSatisfy { $0.end == $1.start }, "段首尾相接")
    check(hour.first?.start == 0 && hour.last?.end == 3600, "从 0 铺到总长")
    let counts = Dictionary(grouping: hour, by: \.spot).mapValues(\.count)
    check(counts.count == 5 && counts.values.allSatisfy { (120...240).contains($0) }, "五处都用到、大致一样多：\(counts)")
    check(WatermarkPlacement.schedule(total: 3600, seed: 7) == hour, "同一个种子同一张表")
    check(WatermarkPlacement.schedule(total: 3600, seed: 8) != hour, "换个种子换一张表")
    let short = WatermarkPlacement.schedule(total: 2.5, seed: 1)
    check(short.count == 1 && short.first?.end == 2.5, "不到 4 秒的成片一段：\(short)")
    let nine = WatermarkPlacement.schedule(total: 9, seed: 1)
    check(nine.map(\.start) == [0, 4, 8] && nine.last?.end == 9, "9 秒三段，最后一段收在 9：\(nine.map { ($0.start, $0.end) })")
    check(WatermarkPlacement.schedule(total: 0, seed: 1).isEmpty, "0 秒没有段")
}

private func layoutChecks() {
    let landscape = CGSize(width: 1920, height: 1080), portrait = CGSize(width: 1080, height: 1920)
    check(WatermarkPlacement.logoWidth(.topLeft, canvas: landscape) == 270, "1080p 的四角 270 宽（短边的 25%）")
    check(WatermarkPlacement.logoWidth(.center, canvas: landscape) == 162, "1080p 的正中 162 宽（短边的 15%）")
    check(WatermarkPlacement.logoWidth(.bottomRight, canvas: portrait) == 270, "竖屏按短边算，同样 270")
    let ink = CGSize(width: 270, height: 173)
    check(WatermarkPlacement.inkOrigin(.topLeft, ink: ink, canvas: landscape) == CGPoint(x: 43, y: 43), "左上离两边各 43（短边的 4%）")
    check(WatermarkPlacement.inkOrigin(.bottomRight, ink: ink, canvas: landscape) == CGPoint(x: 1920 - 43 - 270, y: 1080 - 43 - 173), "右下离两边各 43")
    check(WatermarkPlacement.inkOrigin(.topRight, ink: ink, canvas: portrait) == CGPoint(x: 1080 - 43 - 270, y: 43), "竖屏的右上")
    let middle = CGSize(width: 162, height: 104)
    check(WatermarkPlacement.inkOrigin(.center, ink: middle, canvas: landscape) == CGPoint(x: 879, y: 488), "正中居中")
}

/// 生成的表达式只有两种：数字，或 `if(lt(t,X),A,B)`。照 ffmpeg 的意思求值（lt 是严格小于）。
private func evaluate(_ expression: Substring, t: Double) -> Double? {
    guard expression.hasPrefix("if(lt(t,") else { return Double(expression) }
    let rest = expression.dropFirst("if(lt(t,".count)
    guard let close = rest.firstIndex(of: ")"), let bound = Double(rest[..<close]) else { return nil }
    let branches = rest[rest.index(after: close)...].dropFirst().dropLast()   // 去掉 "," 和最外面的 ")"
    var depth = 0
    for index in branches.indices {
        switch branches[index] {
        case "(": depth += 1
        case ")": depth -= 1
        case "," where depth == 0:
            return t < bound ? evaluate(branches[..<index], t: t) : evaluate(branches[branches.index(after: index)...], t: t)
        default: break
        }
    }
    return nil
}

private func piecewiseChecks() {
    let fmt = VideoEditExportGraph.fmt
    check(WatermarkExport.piecewise([(0, "1"), (4, "1"), (8, "0")], fmt: fmt) == "if(lt(t,8),1,0)", "相邻同值的段并起来")
    check(WatermarkExport.piecewise([(0, "5")], fmt: fmt) == "5", "一段就是常数")
    check(WatermarkExport.piecewise([], fmt: fmt) == "0", "没有段是 0")

    let slots = WatermarkPlacement.schedule(total: 200, seed: 3)
    let expression = WatermarkExport.piecewise(slots.map { ($0.start, String($0.spot.rawValue)) }, fmt: fmt)
    var wrong: [Double] = []
    for step in 0..<800 {
        let t = Double(step) * 0.25
        let expected = slots.first { t >= $0.start && t < $0.end }.map { Double($0.spot.rawValue) }
        if evaluate(expression[...], t: t) != expected { wrong.append(t) }
    }
    check(wrong.isEmpty, "每 0.25 秒求值都和表一致（左闭右开，边界上取后一段）：错在 \(wrong.prefix(5))")
    check(evaluate(expression[...], t: 3.999) == Double(slots[0].spot.rawValue) && evaluate(expression[...], t: 4) == Double(slots[1].spot.rawValue),
          "4 秒那一刻已经是第二段")

    let hour = WatermarkPlacement.schedule(total: 3600, seed: 7)
    let deep = WatermarkExport.piecewise(hour.map { ($0.start, String($0.spot.rawValue)) }, fmt: fmt)
    var depth = 0, deepest = 0
    for character in deep where character == "(" || character == ")" {
        depth += character == "(" ? 1 : -1
        deepest = max(deepest, depth)
    }
    check(deepest <= 2 * 11, "900 段的树是平衡的：最深 \(deepest / 2) 层 if（不超过 11）")
}

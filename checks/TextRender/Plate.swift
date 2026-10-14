import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 底板贴着字（`TextPlate`，2026-10-14 用户拍板「底框贴字宽」）
//
// 量的是渲染器真画出来的底板（实心不透明的底板，字和底板同色，于是不透明像素的外框就是底板），不是按排版推算：
// 横向 = 字宽 + 两边内边距、跟着对齐走（中 / 左 / 右）、几行按最宽那一行、折行处的空格不算；可点范围和画出来的是同一块。
// 以前底板按版面框画，版面框的宽是折行宽度（默认画面的 80%），短标题底下也是一整条。
// 约束见 docs/architecture/text-overlays.md「绘制顺序」之后那一段。

func checkTextPlate() {
    let canvas = CGSize(width: 1280, height: 720)
    let scale = TextOverlay.pixelScale(canvas: canvas)
    var style = TextStyle.default
    style.fontSize = 100
    style.shadow = nil
    style.stroke = nil
    let plate = TextBackground(color: SubtitleColor(red: 1, green: 1, blue: 1, opacity: 1), cornerRadius: 0, paddingX: 28, paddingY: 14)
    style.background = plate
    let padX = plate.paddingX * scale

    func overlay(_ text: String, alignment: TextBlockAlignment = .center, boxWidth: Double = 0.8) -> TextOverlay {
        var shaped = style
        shaped.alignment = alignment
        return TextOverlay(text: text, timelineStart: 0, centerX: 0.5, centerY: 0.5, boxWidth: boxWidth, style: shaped)
    }

    // 1. 短标题：底板只比字宽出两边的内边距，远比 80% 的版面框窄，居中。
    let short = overlay("Hi")
    let frame = TextRenderer.layoutFrame(short, canvas: canvas)
    let layout = TextTypesetter.layout(short, canvas: canvas)
    let textWidth = layout.lines.map { $0.width - $0.trailingWhitespace }.max() ?? 0
    if let drawn = opaqueRect(short, canvas: canvas) {
        checkClose(drawn.width, textWidth + 2 * padX, 3, "短标题的底板 = 字宽 + 两边内边距（字宽 \(textWidth)）")
        check(drawn.width < frame.width * 0.5, "短标题的底板远比 80% 的版面框窄（\(drawn.width) vs \(frame.width)）")
        checkClose(drawn.midX, frame.midX, 2, "居中对齐：底板在版面框正中")
        let hit = TextHitGeometry(short, canvas: canvas)
        let content = hit.contentInFrame.offsetBy(dx: hit.frame.minX, dy: hit.frame.minY)
        check(content.insetBy(dx: -1, dy: -1).contains(drawn), "画出来的底板整块都点得着（\(drawn) 在 \(content) 里）")
        check(content.width <= drawn.width + 2 * TextHitGeometry.contentPadding + 2,
              "可点范围不比底板宽出一大截（\(content.width) vs 底板 \(drawn.width)）：和画的是同一块")
    } else {
        check(false, "带底板的短标题渲不出来")
    }

    // 2. 跟着对齐走：左对齐贴着版面框的左边，右对齐贴着右边。
    if let left = opaqueRect(overlay("Hi", alignment: .leading), canvas: canvas) {
        checkClose(left.minX, frame.minX - padX, 3, "左对齐：底板从版面框左边往外一个内边距起")
    }
    if let right = opaqueRect(overlay("Hi", alignment: .trailing), canvas: canvas) {
        checkClose(right.maxX, frame.maxX + padX, 3, "右对齐：底板到版面框右边往外一个内边距止")
    }

    // 3. 几行：按最宽的那一行。
    let twoLines = overlay("Hello there\nHi")
    let twoLayout = TextTypesetter.layout(twoLines, canvas: canvas)
    let widest = twoLayout.lines.map { $0.width - $0.trailingWhitespace }.max() ?? 0
    if let drawn = opaqueRect(twoLines, canvas: canvas) {
        checkClose(drawn.width, widest + 2 * padX, 3, "两行：底板按最宽那一行（\(widest)）")
    }

    // 4. 自动折行：折行处那个空格不算宽，居中的底板左右对称。
    let wrapped = overlay("Antarctic winter night", boxWidth: 0.4)
    let wrappedLayout = TextTypesetter.layout(wrapped, canvas: canvas)
    check(wrappedLayout.lines.count >= 2, "用例本身：窄框里要折成几行（\(wrappedLayout.lines.count) 行）")
    check(wrappedLayout.lines.contains { $0.trailingWhitespace > 0 }, "用例本身：折行处的行尾有空格")
    if let drawn = opaqueRect(wrapped, canvas: canvas) {
        let wrapFrame = TextRenderer.layoutFrame(wrapped, canvas: canvas)
        checkClose(drawn.midX, wrapFrame.midX, 2, "折行处的空格不算宽：居中的底板左右对称")
    }
}

/// 渲染图里不透明像素的外框，画布坐标（左上原点）。
private func opaqueRect(_ overlay: TextOverlay, canvas: CGSize) -> CGRect? {
    guard let rendered = TextRenderer.render(overlay, canvas: canvas),
          let mask = alphaMask(rendered.image) else { return nil }
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<mask.height {
        for x in 0..<mask.width where mask.alpha[y * mask.width + x] > 128 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(
        x: rendered.origin.x + Double(minX), y: rendered.origin.y + Double(minY),
        width: Double(maxX - minX + 1), height: Double(maxY - minY + 1)
    )
}

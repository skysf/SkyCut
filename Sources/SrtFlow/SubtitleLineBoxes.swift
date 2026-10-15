import CoreText
import Foundation
import SrtFlowCore

// MARK: - 一句字幕按此刻的样式画在画布上占哪一块（纯值）
//
// 管什么：AI 看不见画面，要知道「这句字幕会落在哪、有多宽、折成几行」才能判断它撞没撞上水印、要不要收窄 max_width
// （2026-10-15 用户转来的反馈：三行字幕碰到左下角的台标，AI 只能一帧一帧 look 才发现）。这里按预览 / 烧录同一份口径算：
// - 字体和大小：`SubtitleFontScale.runs`（每一截实际画它的字体、按 libass 的比例缩）；
// - 折行宽度和左右位置：和 `BurnInSubtitleOverlay` 同一个规矩 —— 没有拖框的布局时宽度 = 画面宽 − 两边各一个 marginHorizontal、
//   按九宫格的列对齐；有布局时宽度 = 画面宽 − 左右边距、居中。折行按 libass 的 WrapStyle 0（智能换行：先用最少的行数，再把每行摊匀），
//   用 CoreText 的断行点 + 二分「还装得进这么多行的最小宽度」实现；
// - 竖向：一行按 libass 的量度那么高（`SubtitleLineMetrics`：一行 = 字号），块的上下沿和左右边距只问 `SubtitleFrameGeometry`
//   （拖框、就地编辑用的同一份换算，把算出来的块高喂给它）；
// - 描边 / 底框 / 投影往外多出的那一圈也算进去 —— 撞水印看的是墨迹。
// 坐标先在 1080 高的基准画布上算（宽按画布的宽高比，同 ASS 的 PlayResX），再换成画布的比例（左上原点）。
// 是近似值：预览和成片在几个像素内对齐（check-subtitle-burn-size 钉着那两边），这里和它们的差主要在折行点上。
// 不管什么：哪一句在哪一刻显示、叠在一起的两条轨各占哪一截（`AISubtitleBoxes`）、撞上了什么（`AISubtitleOverlaps`）。

struct SubtitleLineBox: Equatable {
    /// 画布上的框（0…1，左上原点）。
    var rect: CGRect
    /// 折成几行（文字里自带的换行也算）。
    var lineCount: Int
}

enum SubtitleLineBoxes {
    /// 一句（或叠在一起的两句，中间有换行）按样式画出来占哪一块；没有字就是 nil。`canvas` 只用宽高比。
    static func box(for text: String, style: BurnInStyle, layout: SubtitleLayout?, canvas: CGSize) -> SubtitleLineBox? {
        let box = referenceBox(canvas: canvas)
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return nil }
        let fontSize = style.fontSize * (layout?.fontScale ?? 1)
        let usable = usableWidth(box: box, style: style, layout: layout)
        var widths: [Double] = []
        var lineHeight = 0.0
        for paragraph in paragraphs {
            widths += lineWidths(attributed(paragraph, style: style, fontSize: fontSize), maxWidth: usable)
            let runs = SubtitleFontScale.runs(paragraph, style: style)
            let metrics = SubtitleLineMetrics.of(runs, in: paragraph, style: style, fontSize: fontSize)
            lineHeight = max(lineHeight, metrics.ascentLibass + metrics.descentLibass)
        }
        let padding = style.borderStyle == .box ? max(0, style.outlineWidth) : 0
        let blockWidth = min(usable, widths.max() ?? 0) + 2 * padding
        let blockHeight = Double(widths.count) * lineHeight + 2 * padding
        // 块的上下沿、左右边距只问 SubtitleFrameGeometry（拖框、就地编辑同一份换算），块高是刚算出来的。
        let frame = SubtitleFrameGeometry(boxSize: box, style: style, layout: layout, blockHeight: blockHeight).frameRect
        let x: Double
        switch layout == nil ? style.position.column : 1 {
        case 0: x = frame.minX
        case 2: x = frame.maxX - blockWidth
        default: x = frame.midX - blockWidth / 2
        }
        var rect = CGRect(x: x, y: frame.minY, width: blockWidth, height: blockHeight)
        if style.borderStyle == .outline {
            // 描边绕一圈、投影往右下多出一截，都是墨迹。
            rect = rect.insetBy(dx: -style.outlineWidth, dy: -style.outlineWidth)
            rect.size.width += max(0, style.shadowOffset)
            rect.size.height += max(0, style.shadowOffset)
        }
        let normalized = CGRect(
            x: rect.minX / box.width, y: rect.minY / box.height, width: rect.width / box.width, height: rect.height / box.height
        )
        return SubtitleLineBox(rect: normalized, lineCount: widths.count)
    }

    /// 1080 高的基准画布，宽按画布的宽高比（同 `SubtitleLineFit`）。
    static func referenceBox(canvas: CGSize) -> CGSize {
        let height = Double(BurnInStyle.referenceHeight)
        let aspect = canvas.width > 0 && canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9.0
        return CGSize(width: height * aspect, height: height)
    }

    /// 一行最宽能到多少（同 `BurnInSubtitleOverlay.usableWidth`）。
    static func usableWidth(box: CGSize, style: BurnInStyle, layout: SubtitleLayout?) -> Double {
        if let layout { return max(20, box.width - Double(layout.marginLeft) - Double(layout.marginRight)) }
        return max(20, box.width - 2 * Double(style.marginHorizontal))
    }

    /// 这一段折成几行、每行多宽：libass 的 WrapStyle 0（先用最少的行数，再把每行摊匀）—— 先按最大宽度贪心断行得到行数，
    /// 再二分出还装得进这么多行的最小宽度、按它断行；每行的宽不算行尾的空格。
    static func lineWidths(_ paragraph: NSAttributedString, maxWidth: Double) -> [Double] {
        let typesetter = CTTypesetterCreateWithAttributedString(paragraph)
        let length = paragraph.length
        func breaks(at width: Double) -> [CFRange] {
            var ranges: [CFRange] = []
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, max(1, width))
                if count <= 0 { count = length - start }
                ranges.append(CFRange(location: start, length: count))
                start += count
            }
            return ranges
        }
        func width(of range: CFRange) -> Double {
            let line = CTTypesetterCreateLine(typesetter, range)
            return CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
        }
        let greedy = breaks(at: maxWidth)
        guard greedy.count > 1 else { return greedy.map(width) }
        var low = 0.0, high = maxWidth
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if breaks(at: middle).count <= greedy.count { high = middle } else { low = middle }
        }
        return breaks(at: high).map(width)
    }

    /// 每一截按实际画它的字体（回退的也算）、按 libass 的比例缩；字距同预览的 `tracking`。
    private static func attributed(_ text: String, style: BurnInStyle, fontSize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        for run in SubtitleFontScale.runs(text, style: style) {
            let font = SubtitleFontScale.ctFont(named: run.fontName, size: fontSize * run.scale, bold: style.bold, italic: style.italic)
            result.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font, range: run.range)
        }
        if style.letterSpacing != 0 {
            result.addAttribute(
                NSAttributedString.Key(kCTKernAttributeName as String), value: style.letterSpacing,
                range: NSRange(location: 0, length: result.length)
            )
        }
        return result
    }
}

import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 一句字幕按此刻的样式画在画布上占哪一块（纯值）
//
// 管什么：AI 看不见画面，要知道「这句字幕会落在哪、有多宽、折成几行」才能判断它撞没撞上水印、要不要收窄 max_width
// （2026-10-15 用户转来的反馈：三行字幕碰到左下角的台标，AI 只能一帧一帧 look 才发现）。这里按预览 / 烧录同一份口径算：
// - 字体和大小：`SubtitleFontScale.runs`（每一截实际画它的字体、按 libass 的比例缩）；
// - 折行宽度和左右位置：一行最宽到哪只问 `SubtitleLineWrap.usableWidth`（预览、烧录同一个量：没有拖框的布局时 = 画面宽 − 两边各一个
//   marginHorizontal，有布局时 = 画面宽 − 左右边距）；没有布局时按九宫格的列对齐，有布局时居中。在哪儿折行只问 `SubtitleLineWrap`
//   （照 libass 的 WrapStyle 0 摊匀算、中日文在字之间折，预览画的、烧录写的 `\N` 都是它算出来的那几行，2026-10-15）；一个词比可用宽度
//   还宽（超长的英文单词）时不折，这里报的框也照实比画面宽；
// - 竖向：一行按 libass 的量度那么高（`SubtitleLineMetrics`：一行 = 字号），块的上下沿和左右边距只问 `SubtitleFrameGeometry`
//   （拖框、就地编辑用的同一份换算，把算出来的块高喂给它）；
// - 描边 / 底框 / 投影往外多出的那一圈也算进去 —— 撞水印看的是墨迹。
// 坐标先在 1080 高的基准画布上算（宽按画布的宽高比取偶数，就是 ASS 的 PlayResX，`BurnInStyle.playResolution`），再换成画布的比例（左上原点）。
// 预览和成片在几个像素内对齐（check-subtitle-burn-size 钉着那两边，折行点也钉着），这里和它们的差只剩墨迹和步进差的那一两个像素。
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
        let fontSize = style.fontSize * (layout?.fontScale ?? 1)
        let usable = SubtitleLineWrap.usableWidth(canvasWidth: box.width, style: style, layout: layout)
        let runs = SubtitleFontScale.runs(text, style: style)
        // 折成几行、每行多宽：和预览、烧录同一份（SubtitleLineWrap）；空的自然段不算。
        let lines = SubtitleLineWrap.lines(
            of: text, runs: runs, style: style, fontSize: fontSize, letterSpacing: style.letterSpacing, maxWidth: usable
        )
        guard !lines.isEmpty else { return nil }
        let metrics = SubtitleLineMetrics.of(runs, in: text, style: style, fontSize: fontSize)
        let lineHeight = metrics.ascentLibass + metrics.descentLibass
        let padding = style.borderStyle == .box ? max(0, style.outlineWidth) : 0
        // 一个词比可用宽度还宽（超长的英文单词）时不折：框也照实报，不夹到边距里。
        let blockWidth = (lines.map(\.width).max() ?? 0) + 2 * padding
        // 行距：两行之间多出的那一截和烧录的垫片、预览的间距同一个数（`BurnInStyle.lineSpacing`，一行高 = 字号）。
        let blockHeight = Double(lines.count) * lineHeight + Double(lines.count - 1) * (style.lineSpacing - 1) * fontSize + 2 * padding
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
        return SubtitleLineBox(rect: normalized, lineCount: lines.count)
    }

    /// 1080 高的基准画布，宽按画布的宽高比取偶数 —— 就是烧录 ASS 的 PlayResX / PlayResY（`BurnInStyle.playResolution`）。
    static func referenceBox(canvas: CGSize) -> CGSize {
        let aspect = canvas.width > 0 && canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9.0
        let resolution = BurnInStyle.playResolution(aspectRatio: aspect)
        return CGSize(width: Double(resolution.width), height: Double(resolution.height))
    }
}

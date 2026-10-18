import CoreText
import Foundation
import SrtFlowCore

// MARK: - 一句字幕在哪儿折行：预览、AI 读的框、成片同一份（纯值）
//
// 管什么：一句太长、一行放不下的字幕，预览（`BurnInSubtitleOverlay`）、AI 读的框（`SubtitleLineBoxes`）和成片（libass）要在
// **同一个地方**折行。以前预览让 SwiftUI 的 Text 自己折（贪心：第一行填满、第二行剩一点），成片是 libass 的 WrapStyle 0
// （先贪心、再把上一行末尾的词往下挪到两行差不多宽），box 又是第三种（二分最小宽度）—— 同一句字三个地方折在三处
// （2026-10-15 真机量到：预览第一行 0.058–0.941，成片 0.184–0.815）。现在折行点只在这里算一份：预览照它画，烧录把它写成 `\N`
// 并关掉 libass 自己的折行（WrapStyle 2，`BurnInWorkspace.prewrapped`），libass 只照着画。
//
// 两种段两种折法（2026-10-18 起，docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md）：
// - **没有中日文的段**（英文、韩文……）照抄 libass 0.17 `ass_render.c` 的 `wrap_lines_naive` + `wrap_lines_rebalance` + `trim_whitespace`
//   （2026-10-15 对着源码 port，用 vendor/ffmpeg 真烧一帧核过）：
//   1. 贪心：从行首第一个字的墨迹左沿量到当前字的墨迹右沿，≥ 最大宽就在**上一个空格之后**断（当前字是空格不算溢出）；没有就不断、
//      整行溢出（一个超长的英文单词）。韩文词之间本来就有空格，也只在空格处断。
//   2. 摊匀：每一轮对每一对相邻的软断行，把上一行最后一个词挪到下一行开头，只要两行宽度之差变小就挪；挪过就再来一轮，直到没有能挪的。
//      上一行只剩一个词时跳过这一对（不合并）。
// - **有中日文的段**交给 `SubtitleCJKRows`：能在哪儿断、断在那儿好不好问 SrtFlowCore 的 `SubtitleRowBreaks`（中日文只在词和词之间断、
//   句中的空格和标点后面好断、助词不起头……），最少几行能放下就几行，再挑摊匀 + 断点代价最小的那种。2026-10-15 到 10-18 之间中日文是
//   「任意两个字之间都能断、只按宽度摊匀」，词被拆在两行（「抖 / 音」「以 / 及」「Nano / Banana」），句中的空格（去掉的逗号）反而不优先。
// 两种都一样：行首行尾的空格不画、不算宽（多个连着的空格也一样）；一行的宽 = 这一行每个字的步进加起来（libass 居中按它，不按墨迹）；
// 换行符是硬断（按自然段拆开各自折，换行不是字）。烧录照这里的折行点写 `\N`、关掉 libass 自己的折行（WrapStyle 2，
// `BurnInWorkspace.prewrapped`，2026-10-15 用户定：vendor/ffmpeg 的 libass 只在 ASCII 空格处折，没有空格的长中文句以前整行溢出）。
// 字的宽从 Core Text 来：每一截按实际画它的字体（`SubtitleFontScale.runs`，回退的也算、按 libass 的比例缩），亮着的词按倍数放大
// （烧录的 `\fscx` / `\fscy` 也放大，折行要算上）。glyph 的墨迹左右沿用字体的 bounding box，空格当零宽（libass 里空的轮廓 bbox 是 0）。
// 一行最宽到哪（`usableWidth`）也只在这里算一份：没有拖框的布局时 = 画面宽 − 两边各一个 marginHorizontal，有布局时 = 画面宽 − 左右边距
// （和 libass 的 PlayResX − MarginL − MarginR 同一个量）。
// 不管什么：一行多高、摆在哪（`SubtitleLineMetrics` / `SubtitleFrameGeometry`）、怎么画（`BurnInSubtitleOverlay`）、怎么写成 ASS
// （`BurnInWorkspace` / `BurnInStyle.assDocument`）。

enum SubtitleLineWrap {
    /// 折出来的一行。
    struct Line: Equatable {
        /// 在整句字里的位置（UTF-16），行首行尾的空格已经去掉；空行（只有空格）长度为 0。
        var range: NSRange
        /// 这一行的宽：每个字的步进加起来（居中按它）。
        var width: Double
    }

    /// 一行最宽能到多少：`canvasWidth` 是画面宽，`scale` 是样式里的边距（1080 基准像素）换到这个画面要乘的倍数（预览传预览像素和它的
    /// 缩放；1080 基准的画布就传基准宽、scale 1）。预览、AI 读的框、烧录三处同一个量。
    static func usableWidth(canvasWidth: Double, style: BurnInStyle, layout: SubtitleLayout?, scale: Double = 1) -> Double {
        if let layout { return max(20, canvasWidth - Double(layout.marginLeft + layout.marginRight) * scale) }
        return max(20, canvasWidth - 2 * Double(style.marginHorizontal) * scale)
    }

    /// 一句字（可以带换行）折成几行：每个自然段各自折，空的自然段不要（字幕里没有空行）。
    /// - Parameters:
    ///   - runs: 每一截实际画它的字体（`SubtitleFontScale.runs(text, style:)`）。
    ///   - fontSize: 样式的字号换算到像素（预览传预览像素，1080 基准就传 1080 基准）。
    ///   - letterSpacing: 字距（同一个单位）。
    ///   - maxWidth: 一行最宽到哪（同一个单位，`usableWidth`）。
    ///   - lit: 此刻亮着的词（整句里的位置）；`litScale` 它们放大的倍数。
    static func lines(
        of text: String, runs: [SubtitleFontScale.Run], style: BurnInStyle, fontSize: Double, letterSpacing: Double,
        maxWidth: Double, lit: [NSRange] = [], litScale: Double = 1
    ) -> [Line] {
        let whole = text as NSString
        var result: [Line] = []
        var start = 0
        while start <= whole.length {
            let newline = whole.range(of: "\n", range: NSRange(location: start, length: whole.length - start))
            let end = newline.location == NSNotFound ? whole.length : newline.location
            let paragraph = NSRange(location: start, length: end - start)
            if whole.substring(with: paragraph).contains(where: { $0 != " " }) {
                let attributed = attributed(
                    whole, in: paragraph, runs: runs, style: style, fontSize: fontSize, letterSpacing: letterSpacing,
                    lit: lit, litScale: litScale
                )
                result += wrap(attributed, maxWidth: maxWidth).map {
                    Line(range: NSRange(location: $0.range.location + paragraph.location, length: $0.range.length), width: $0.width)
                }
            }
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return result
    }

    /// 折好的几行写回成一句字（行间是换行，行首行尾的空格已经去掉）—— 烧录照它写 `\N`；`lit` 里每个词换算到新的字里的位置
    /// （跨行的词拆成两截）。空的自然段不进来，和预览画的一样。
    static func joined(_ lines: [Line], of text: String, lit: [NSRange]) -> (text: String, lit: [NSRange]) {
        let whole = text as NSString
        var result = ""
        var ranges: [NSRange] = []
        var offset = 0
        for (k, line) in lines.enumerated() {
            if k > 0 {
                result += "\n"
                offset += 1
            }
            result += whole.substring(with: line.range)
            for word in lit {
                let overlap = NSIntersectionRange(word, line.range)
                guard overlap.length > 0 else { continue }
                ranges.append(NSRange(location: offset + overlap.location - line.range.location, length: overlap.length))
            }
            offset += line.range.length
        }
        return (result, ranges)
    }

    // MARK: 排字

    /// `text` 的 `range` 这一段（一个自然段）排成带字体的字：每一截用 `runs` 里实际画它的字体、按 libass 的比例缩，亮着的词再放大，
    /// 字距同预览的 `tracking`。
    private static func attributed(
        _ text: NSString, in range: NSRange, runs: [SubtitleFontScale.Run], style: BurnInStyle, fontSize: Double,
        letterSpacing: Double, lit: [NSRange], litScale: Double
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.substring(with: range))
        let fallback = SubtitleFontScale.ctFont(named: style.fontName, size: fontSize, bold: style.bold, italic: style.italic)
        result.addAttribute(.init(kCTFontAttributeName as String), value: fallback, range: NSRange(location: 0, length: range.length))
        for run in runs {
            let overlap = NSIntersectionRange(run.range, range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            // 亮着的词在这一截里的部分放大：先整截按常规大小，再给亮着的那几段换大字。
            let normal = SubtitleFontScale.ctFont(named: run.fontName, size: fontSize * run.scale, bold: style.bold, italic: style.italic)
            result.addAttribute(.init(kCTFontAttributeName as String), value: normal, range: local)
            guard litScale != 1 else { continue }
            let big = SubtitleFontScale.ctFont(named: run.fontName, size: fontSize * run.scale * litScale, bold: style.bold, italic: style.italic)
            for word in lit {
                let litOverlap = NSIntersectionRange(word, overlap)
                guard litOverlap.length > 0 else { continue }
                result.addAttribute(
                    .init(kCTFontAttributeName as String), value: big,
                    range: NSRange(location: litOverlap.location - range.location, length: litOverlap.length)
                )
            }
        }
        if letterSpacing != 0 {
            result.addAttribute(.init(kCTKernAttributeName as String), value: letterSpacing, range: NSRange(location: 0, length: range.length))
        }
        return result
    }

    /// 一个字（glyph）在一行里的账：libass 的 `GlyphInfo` 里折行要用的那几样（中日文的段交给 `SubtitleCJKRows` 时也是这份）。
    struct Glyph {
        /// 在这一段里的位置（UTF-16）。
        var index: Int
        /// 是不是 ASCII 空格（libass 只把它当空白）。
        var isSpace: Bool
        /// 步进（含字距）。
        var advance: Double
        /// 墨迹的左右沿（空格当零宽、落在笔的位置上）。
        var inkLeft: Double
        var inkRight: Double
    }

    /// 这一段排成一行（不折）之后每个字的位置和墨迹，按字的先后排。
    private static func glyphs(of paragraph: NSAttributedString) -> [Glyph] {
        let line = CTLineCreateWithAttributedString(paragraph)
        let string = paragraph.string as NSString
        var result: [Glyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var ids = [CGGlyph](repeating: 0, count: count)
            var bounds = [CGRect](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
            if let attributes = CTRunGetAttributes(run) as? [String: Any],
               let font = attributes[kCTFontAttributeName as String] {
                CTFontGetBoundingRectsForGlyphs(font as! CTFont, .horizontal, ids, &bounds, count)
            }
            for k in 0..<count {
                let inside = indices[k] < string.length
                let isSpace = inside && string.character(at: indices[k]) == 0x20
                let pen = Double(positions[k].x)
                let box = isSpace || bounds[k].isNull || bounds[k].isEmpty ? CGRect(x: 0, y: 0, width: 0, height: 0) : bounds[k]
                result.append(Glyph(
                    index: indices[k], isSpace: isSpace, advance: Double(advances[k].width),
                    inkLeft: pen + Double(box.minX), inkRight: pen + Double(box.maxX)
                ))
            }
        }
        return result.sorted { $0.index < $1.index }
    }

    // MARK: 能在哪儿起新一行（没有中日文的段）

    /// 第 `i` 个字前面能不能起新一行：空格之后（libass 本来的规矩）。有中日文的段不走这里（`SubtitleCJKRows`）。
    private static func startsRow(_ g: [Glyph], at i: Int) -> Bool {
        i > 0 && !g[i].isSpace && g[i - 1].isSpace
    }

    // MARK: libass 的三步

    /// 一个自然段折成几行（位置相对这一段）：有中日文的段交给 `SubtitleCJKRows`，其余照 libass。
    static func wrap(_ paragraph: NSAttributedString, maxWidth: Double) -> [Line] {
        let g = glyphs(of: paragraph)
        guard !g.isEmpty else { return [] }
        if SubtitleRowBreaks.isCJK(paragraph.string) {
            let soft = SubtitleCJKRows.softBreaks(g, text: paragraph.string, maxWidth: maxWidth)
            return trimmed(g, soft: soft, length: paragraph.length)
        }
        var soft = [Bool](repeating: false, count: g.count)   // 这个字前面断一行（软断：摊匀时可以挪）
        wrapNaive(g, maxWidth: maxWidth, soft: &soft)
        rebalance(g, soft: &soft)
        return trimmed(g, soft: soft, length: paragraph.length)
    }

    /// `wrap_lines_naive`：溢出就在上一个能起行的地方断。
    private static func wrapNaive(_ g: [Glyph], maxWidth: Double, soft: inout [Bool]) {
        var lineStart = 0
        var lastStart = -1   // 这一行里最后一个能起新行的字（libass 的 last_breakable + 1）
        for i in g.indices {
            if i > lineStart, startsRow(g, at: i) { lastStart = i }
            let length = g[i].inkRight - g[lineStart].inkLeft
            if length >= maxWidth, !g[i].isSpace, lastStart > lineStart {
                soft[lastStart] = true
                lineStart = lastStart
                lastStart = -1
            }
        }
    }

    /// `wrap_lines_rebalance`：把上一行最后一个词往下挪，只要两行宽度之差变小。
    private static func rebalance(_ g: [Glyph], soft: inout [Bool]) {
        /// `rewind_trailing_spaces`：从 `end` 往回退到第一个不是空格的字（最多退到 `start`）。
        func lastInk(from start: Int, before end: Int) -> Int {
            var k = end
            repeat { k -= 1 } while k > start && g[k].isSpace
            return k
        }
        var moved = true
        while moved {
            moved = false
            var s1: Int? = nil, s2: Int? = nil, s3 = 0
            for i in 0...g.count {
                guard i == g.count || soft[i] else { continue }
                s1 = s2; s2 = s3; s3 = i
                guard let first = s1, let second = s2, soft[second] else { continue }
                let e1Old = lastInk(from: first, before: second)
                // 上一行最后一个词从哪儿起：往回找最后一个能起行的地方（空格之后）。
                var w = e1Old
                while w > first, !startsRow(g, at: w) { w -= 1 }
                if w <= first { continue }   // 上一行只有一个词：不合并
                var e1 = w - 1
                while e1 > first, g[e1].isSpace { e1 -= 1 }
                let e2 = lastInk(from: second, before: s3)
                let l1 = g[e1Old].inkRight - g[first].inkLeft
                let l2 = g[e2].inkRight - g[second].inkLeft
                let l1New = g[e1].inkRight - g[first].inkLeft
                let l2New = g[e2].inkRight - g[w].inkLeft
                if abs(l1New - l2New) < abs(l1 - l2) {
                    soft[w] = true
                    soft[second] = false
                    s2 = w
                    moved = true
                }
            }
        }
    }

    /// `trim_whitespace` + `align_lines` 里算宽那一段：每行去掉两头的空格，宽 = 剩下的字的步进之和。
    private static func trimmed(_ g: [Glyph], soft: [Bool], length: Int) -> [Line] {
        var starts = [0]
        for i in g.indices where soft[i] && i > 0 { starts.append(i) }
        return zip(starts, starts.dropFirst() + [g.count]).map { from, to in
            var first = from, last = to - 1
            while first <= last, g[first].isSpace { first += 1 }
            while last >= first, g[last].isSpace { last -= 1 }
            guard first <= last else {
                return Line(range: NSRange(location: g[from].index, length: 0), width: 0)
            }
            let end = last + 1 < g.count ? g[last + 1].index : length
            let width = (first...last).reduce(0.0) { $0 + g[$1].advance }
            return Line(range: NSRange(location: g[first].index, length: end - g[first].index), width: width)
        }
    }
}

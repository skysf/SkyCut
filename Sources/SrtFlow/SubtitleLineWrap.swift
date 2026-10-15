import CoreText
import Foundation
import SrtFlowCore

// MARK: - 一句字幕在哪儿折行：照 libass 的 WrapStyle 0 算（纯值）
//
// 管什么：一句太长、一行放不下的字幕，预览（`BurnInSubtitleOverlay`）、AI 读的框（`SubtitleLineBoxes`）和成片（libass）要在
// **同一个地方**折行。以前预览让 SwiftUI 的 Text 自己折（贪心：第一行填满、第二行剩一点），成片是 libass 的 WrapStyle 0
// （先贪心、再把上一行末尾的词往下挪到两行差不多宽），box 又是第三种（二分最小宽度）—— 同一句字三个地方折在三处
// （2026-10-15 真机量到：预览第一行 0.058–0.941，成片 0.184–0.815）。现在折行点只在这里算一份。
//
// 算法照抄 libass 0.17 `ass_render.c` 的 `wrap_lines_naive` + `wrap_lines_rebalance` + `trim_whitespace`（2026-10-15 对着源码port，
// 用 vendor/ffmpeg 真烧一帧核过）：
// 1. 贪心：从行首第一个字的墨迹左沿量到当前字的墨迹右沿，≥ 最大宽就在**上一个空格**处断（当前字是空格不算溢出）；没有空格就不断
//    —— libass 只在 ASCII 空格处折行（没编 libunibreak、ffmpeg 也没开 ASS_FEATURE_WRAP_UNICODE），**中文没有空格就不折、整行溢出**；
//    换行符是硬断（这里按自然段拆开各自折，换行不是字）。
// 2. 摊匀：每一轮对每一对相邻的软断行，把上一行最后一个词挪到下一行开头，只要两行宽度之差变小就挪；挪过就再来一轮，直到没有能挪的。
//    上一行只有一个词时跳过这一对（不合并）。
// 3. 行首行尾的空格不画、不算宽（多个连着的空格也一样）；一行的宽 = 这一行每个字的步进加起来（libass 居中按它，不按墨迹）。
// 字的宽从 Core Text 来：每一截按实际画它的字体（`SubtitleFontScale.runs`，回退的也算、按 libass 的比例缩），亮着的词按倍数放大
// （烧录的 `\fs` 也放大，折行要算上）。glyph 的墨迹左右沿用字体的 bounding box，空格当零宽（libass 里空的轮廓 bbox 是 0）。
// 不管什么：一行多高、摆在哪（`SubtitleLineMetrics` / `SubtitleFrameGeometry`）、怎么画（`BurnInSubtitleOverlay`）。

enum SubtitleLineWrap {
    /// 折出来的一行。
    struct Line: Equatable {
        /// 在整句字里的位置（UTF-16），行首行尾的空格已经去掉；空行（只有空格）长度为 0。
        var range: NSRange
        /// 这一行的宽：每个字的步进加起来（居中按它）。
        var width: Double
    }

    /// 一句字（可以带换行）折成几行：每个自然段各自折，空的自然段不要（字幕里没有空行）。
    /// - Parameters:
    ///   - runs: 每一截实际画它的字体（`SubtitleFontScale.runs(text, style:)`）。
    ///   - fontSize: 样式的字号换算到像素（预览传预览像素，1080 基准就传 1080 基准）。
    ///   - letterSpacing: 字距（同一个单位）。
    ///   - maxWidth: 一行最宽到哪（同一个单位，`BurnInSubtitleOverlay.usableWidth` / `SubtitleLineBoxes.usableWidth`）。
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

    /// 一个字（glyph）在一行里的账：libass 的 `GlyphInfo` 里折行要用的那几样。
    private struct Glyph {
        /// 在这一段里的位置（UTF-16）。
        var index: Int
        /// 是不是 ASCII 空格（libass 只在它这儿折、只把它当空白）。
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
                let isSpace = indices[k] < string.length && string.character(at: indices[k]) == 0x20
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

    // MARK: libass 的三步

    /// 一个自然段折成几行（位置相对这一段）。
    static func wrap(_ paragraph: NSAttributedString, maxWidth: Double) -> [Line] {
        let g = glyphs(of: paragraph)
        guard !g.isEmpty else { return [] }
        var soft = [Bool](repeating: false, count: g.count)   // 这个字前面断一行（软断：摊匀时可以挪）
        wrapNaive(g, maxWidth: maxWidth, soft: &soft)
        rebalance(g, soft: &soft)
        return trimmed(g, soft: soft, length: paragraph.length)
    }

    /// `wrap_lines_naive`：溢出就在上一个空格处断。
    private static func wrapNaive(_ g: [Glyph], maxWidth: Double, soft: inout [Bool]) {
        var lineStart = 0
        var lastBreakable = -1
        for i in g.indices {
            let length = g[i].inkRight - g[lineStart].inkLeft
            var breakAt = -1
            if length >= maxWidth, !g[i].isSpace { breakAt = lastBreakable }
            if g[i].isSpace { lastBreakable = i }
            if breakAt != -1, breakAt + 1 < g.count {
                soft[breakAt + 1] = true
                lastBreakable = -1
                lineStart = breakAt + 1
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
                var w = e1Old
                while w > first, !g[w].isSpace { w -= 1 }
                var e1 = w
                while e1 > first, g[e1].isSpace { e1 -= 1 }
                if g[w].isSpace { w += 1 }
                if w == first { continue }   // 上一行只有一个词：不合并
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

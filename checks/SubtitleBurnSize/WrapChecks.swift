import AppKit
import SrtFlowCore

// 预览和成片在同一个地方折行（2026-10-15，docs/bugfixes/2026-10-15-subtitle-preview-wraps-greedily.md）：一句放不进一行的字幕，
// 以前预览让 SwiftUI 的 Text 自己折 —— 贪心，第一行填满、第二行剩一点（真机量到第一行 x 0.058–0.941）；成片是 libass 的 WrapStyle 0，
// 两行摊匀（0.184–0.815）。位置自检（PositionChecks.swift）的两行样本都带显式换行，自动折行从没量过，所以一直绿。
// 现在折行点只有 SubtitleLineWrap 一份（照 libass 0.17 的 wrap_lines_naive + wrap_lines_rebalance + trim_whitespace port），
// 预览一行一个 Text、只画算好的那一行。这里：
// 1. 几种放不进一行的句子（两行 / 三行 / 五行、中英混排、很长的单词、布局覆盖左右不对称、9:16、左 / 右对齐、逐词高亮放大、两个空格、
//    带换行、没有空格的中文），预览离屏渲一张、真烧一帧，按墨迹的空白行切成几行，比**行数**和**每一行**的左右沿（容差 4 px，1080p；
//    折在别处至少差一个词、几十 px）。没有空格的中文 libass 不折、整行溢出到画面两边，预览也要一样溢出。
// 2. 预览每一行的墨迹宽要和 SubtitleLineWrap 算的步进宽对得上（差一个词就红）—— 管的是叠层按行切 piece 没切错。
// 3. 钉几条 libass 的规矩本身（不烧、纯算）：100 号五行的每一行是哪几个字（「二分最小宽度」那种算法在这句上会折在别处）；行首行尾的空格
//    不进行；换行符各自成段；亮着的词放大会把那一行变宽；没有空格的中文一行、比可用宽度宽，`SubtitleLineBoxes` 报的框也照实比画面宽。
// 编法见 scripts/check-subtitle-burn-size.sh。不管什么：字的大小（main.swift）、竖向位置（PositionChecks.swift）、阴影（ShadowChecks.swift）。

/// 预览和成片每一行的左右沿最多差这么多像素（1080p 画布；折在别处差几十 px）。
private let wrapTolerance = 4.0

private struct WrapCase {
    var name: String
    var text: String
    var style: BurnInStyle
    var layout: SubtitleLayout? = nil
    var canvas = CGSize(width: 1920, height: 1080)
    var highlights: [SubtitleTextRange] = []
    var highlight: SubtitleWordHighlight? = nil
    /// 这句该折成几行（libass 真烧出来的；样本本身要真的折了才算量到）。
    var rows: Int
}

private let reported = "This is a much longer subtitle line that goes on and on so that it has to wrap onto a second line at the bottom"
private let threeRows = "When the expedition finally reached the edge of the ice shelf, the penguins had already gathered in their thousands, "
    + "waiting for the long polar night to lift and for the first light of spring"
private let mixed = "南极的冰山 and the penguins 在风里 walking slowly across the ice 一望无际 while the wind keeps blowing"
private let longWords = "Supercalifragilisticexpialidocious antidisestablishmentarianism pneumonoultramicroscopicsilicovolcanoconiosis "
    + "floccinaucinihilipilification honorificabilitudinitatibus"
private let chinese = "南极的冰山一望无际企鹅成群结队地站在风里等待漫长的极夜过去等待春天第一缕阳光照在冰盖上然后再等一个夏天和一个秋天才回到海里去"
private let chineseSpaced = "南极的冰山一望无际 企鹅成群结队地站在风里 等待漫长的极夜过去 等待春天第一缕阳光照在冰盖上 然后再等一个夏天"

/// 默认样式（Helvetica 粗体 56 底部居中）换个对齐、去掉描边（描边 3 的那一种单独一个用例）。
private func wrapStyle(position: SubtitlePosition = .bottomCenter, outline: Double = 0, letterSpacing: Double = 0) -> BurnInStyle {
    var style = BurnInStyle.default
    style.outlineWidth = outline
    style.position = position
    style.letterSpacing = letterSpacing
    return style
}

private let wrapWord = (reported as NSString).range(of: "wrap")
private let wrapCases: [WrapCase] = [
    WrapCase(name: "reported sentence", text: reported, style: wrapStyle(), rows: 2),
    WrapCase(name: "reported sentence, outline 3", text: reported, style: BurnInStyle.default, rows: 2),
    WrapCase(name: "three rows", text: threeRows, style: wrapStyle(), rows: 3),
    WrapCase(name: "three rows, bottom left", text: threeRows, style: wrapStyle(position: .bottomLeft), rows: 3),
    WrapCase(name: "three rows, top right", text: threeRows, style: wrapStyle(position: .topRight), rows: 3),
    WrapCase(name: "five rows at 100", text: threeRows,
             style: BurnInStyle(name: "check", fontName: "Helvetica", fontSize: 100, bold: false, outlineWidth: 0, position: .middleCenter), rows: 5),
    WrapCase(name: "mixed Chinese and English", text: mixed, style: wrapStyle(), rows: 2),
    WrapCase(name: "mixed, Hiragino", text: mixed, style: { var s = wrapStyle(); s.fontName = "Hiragino Sans GB"; return s }(), rows: 2),
    WrapCase(name: "very long words", text: longWords, style: wrapStyle(), rows: 3),
    WrapCase(name: "Chinese without spaces overflows", text: chinese, style: wrapStyle(), rows: 1),
    WrapCase(name: "Chinese with spaces", text: chineseSpaced, style: wrapStyle(), rows: 2),
    WrapCase(name: "dragged layout 500 / 100", text: reported, style: wrapStyle(),
             layout: SubtitleLayout(marginLeft: 500, marginRight: 100, marginBottom: 200), rows: 2),
    WrapCase(name: "9:16", text: reported, style: wrapStyle(), canvas: CGSize(width: 608, height: 1080), rows: 6),
    WrapCase(name: "highlighted word enlarged", text: reported, style: wrapStyle(),
             highlights: [SubtitleTextRange(location: wrapWord.location, length: wrapWord.length)],
             highlight: SubtitleWordHighlight(color: .yellow, scale: 1.2), rows: 2),
    WrapCase(name: "double space inside", text: reported.replacingOccurrences(of: "much longer", with: "much  longer"), style: wrapStyle(), rows: 2),
    WrapCase(name: "letter spacing 3", text: reported, style: wrapStyle(letterSpacing: 3), rows: 2),
    WrapCase(name: "a line break then a long paragraph", text: "short first line\n" + reported, style: wrapStyle(), rows: 3)
]

/// 亮字的墨迹按空白行切成几行（黑底白字）：连着的有墨迹的行是一行，中间空 `gap` 行以上算换行。
func textBands(_ image: CGImage, gap: Int = 3) -> [CGRect] {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return [] }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rows: [(minX: Int, maxX: Int)?] = []
    for y in 0..<height {
        var minX = width, maxX = -1
        for x in 0..<width where pixels[y * width + x] > 128 { minX = min(minX, x); maxX = max(maxX, x) }
        rows.append(maxX < 0 ? nil : (minX, maxX))
    }
    var result: [CGRect] = []
    var y = 0
    while y < height {
        guard let row = rows[y] else { y += 1; continue }
        var bottom = y, minX = row.minX, maxX = row.maxX, blank = 0, k = y + 1
        while k < height {
            if let r = rows[k] { blank = 0; bottom = k; minX = min(minX, r.minX); maxX = max(maxX, r.maxX) }
            else { blank += 1; if blank >= gap { break } }
            k += 1
        }
        result.append(CGRect(x: minX, y: y, width: maxX - minX + 1, height: bottom - y + 1))
        y = k
    }
    return result
}

private func describe(_ bands: [CGRect]) -> String {
    bands.map { "\(Int($0.minX))…\(Int($0.maxX))" }.joined(separator: " | ")
}

/// 这一句按 SubtitleLineWrap 该折成哪几行（和预览喂同一份字号、字距、可用宽度）。
private func computedLines(_ item: WrapCase) -> [SubtitleLineWrap.Line] {
    let scale = item.canvas.height / Double(BurnInStyle.referenceHeight)
    let fontSize = item.style.fontSize * (item.layout?.fontScale ?? 1) * scale
    let usable: Double
    if let layout = item.layout {
        usable = max(20, item.canvas.width - Double(layout.marginLeft + layout.marginRight) * scale)
    } else {
        usable = max(20, item.canvas.width - 2 * Double(item.style.marginHorizontal) * scale)
    }
    return SubtitleLineWrap.lines(
        of: item.text, runs: SubtitleFontScale.runs(item.text, style: item.style), style: item.style, fontSize: fontSize,
        letterSpacing: item.style.letterSpacing * scale, maxWidth: usable,
        lit: item.highlights.map { NSRange(location: $0.location, length: $0.length) }, litScale: item.highlight?.scale ?? 1
    )
}

func runWrapChecks(ffmpeg: String) {
    for item in wrapCases {
        let label = "wrap: \(item.name)"
        let preview = MainActor.assumeIsolated {
            previewImage(item.text, style: item.style, layout: item.layout, canvas: item.canvas, highlights: item.highlights, highlight: item.highlight)
        }
        let burned = burnFrame(item.text, style: item.style, layout: item.layout, canvas: item.canvas,
                               highlights: item.highlights, highlight: item.highlight, ffmpeg: ffmpeg)
        guard let preview, let burned else {
            check(false, "\(label): could not render")
            continue
        }
        let previewRows = textBands(preview), burnedRows = textBands(burned)
        print("\(label): preview x \(describe(previewRows)); burned x \(describe(burnedRows))")
        check(burnedRows.count == item.rows, "\(label): libass wraps it into \(burnedRows.count) rows, the sample expects \(item.rows)")
        check(previewRows.count == burnedRows.count,
              "\(label): the preview wraps into \(previewRows.count) rows, burned \(burnedRows.count)")
        for (row, (p, b)) in zip(previewRows, burnedRows).enumerated() {
            check(abs(p.minX - b.minX) <= wrapTolerance && abs(p.maxX - b.maxX) <= wrapTolerance,
                  "\(label): row \(row + 1) spans x \(Int(p.minX))…\(Int(p.maxX)) in the preview, \(Int(b.minX))…\(Int(b.maxX)) burned")
        }
        // 叠层画的每一行就是 SubtitleLineWrap 算的那一行（墨迹比步进窄一点：两头的边距）；比画面还宽的一行（没有空格的中文）
        // 画布把它裁掉了，只能看它是不是真的铺满了整个画面。
        let computed = computedLines(item)
        check(computed.count == previewRows.count, "\(label): SubtitleLineWrap gives \(computed.count) rows, the preview drew \(previewRows.count)")
        for (row, (p, line)) in zip(previewRows, computed).enumerated() {
            if line.width > item.canvas.width {
                check(p.width >= item.canvas.width - wrapTolerance,
                      "\(label): row \(row + 1) should overflow the whole canvas, the preview drew \(Int(p.width)) of \(Int(item.canvas.width)) px")
            } else {
                check(abs(p.width - line.width) <= max(8, line.width * 0.01),
                      "\(label): row \(row + 1) is \(Int(p.width)) px wide in the preview, SubtitleLineWrap says \(Int(line.width))")
            }
        }
    }
    runWrapRuleChecks()
}

/// libass 的规矩本身（纯算，不烧）。
private func runWrapRuleChecks() {
    func lines(_ text: String, style: BurnInStyle, maxWidth: Double = 1760, lit: [NSRange] = [], litScale: Double = 1) -> [SubtitleLineWrap.Line] {
        SubtitleLineWrap.lines(of: text, runs: SubtitleFontScale.runs(text, style: style), style: style, fontSize: style.fontSize,
                               letterSpacing: style.letterSpacing, maxWidth: maxWidth, lit: lit, litScale: litScale)
    }
    func texts(_ lines: [SubtitleLineWrap.Line], in text: String) -> [String] {
        lines.map { (text as NSString).substring(with: $0.range) }
    }
    // 100 号五行：每一轮把上一行最后一个词挪下去、只要两行差变小（libass 真烧出来就是这几行）；按「二分最小宽度」折会是别的几行。
    let hundred = BurnInStyle(name: "check", fontName: "Helvetica", fontSize: 100, bold: false, outlineWidth: 0, position: .middleCenter)
    let five = texts(lines(threeRows, style: hundred), in: threeRows)
    check(five == ["When the expedition finally reached the edge", "of the ice shelf, the penguins had already",
                   "gathered in their thousands, waiting", "for the long polar night to lift", "and for the first light of spring"],
          "wrap rules: the five rows at 100 are libass's rows (got \(five))")
    // 两行摊匀：第一行不再填满。
    let two = lines(reported, style: wrapStyle())
    check(two.count == 2 && abs(two[0].width - two[1].width) < 100, "wrap rules: two rows end up about as wide (\(two.map(\.width)))")
    check(two.allSatisfy { $0.width <= 1760 }, "wrap rules: no row wider than the usable width when there are spaces to break at")
    // 行首行尾的空格不进行、换行符各自成段。
    let spaced = "  short first line \n" + reported.replacingOccurrences(of: "much longer", with: "much  longer")
    let rows = texts(lines(spaced, style: wrapStyle()), in: spaced)
    check(rows.count == 3 && rows[0] == "short first line", "wrap rules: a line break ends a paragraph, surrounding spaces are not drawn (got \(rows))")
    check(rows.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") }, "wrap rules: rows never start or end with a space (got \(rows))")
    check(rows[1].contains("much  longer"), "wrap rules: a double space inside a row stays (got \(rows[1]))")
    // 亮着的词放大，那一行跟着变宽（烧录的 \fs 也放大）。
    let lit = lines(reported, style: wrapStyle(), lit: [wrapWord], litScale: 1.2)
    check(lit.count == 2 && lit[1].width > two[1].width + 5, "wrap rules: an enlarged highlighted word widens its row (\(lit.map(\.width)) vs \(two.map(\.width)))")
    // 没有空格的中文不折、整行比可用宽度宽；报给 AI 的框也照实比画面宽。
    let cjk = lines(chinese, style: wrapStyle())
    check(cjk.count == 1 && cjk[0].width > 1760, "wrap rules: Chinese without spaces is one row wider than the frame (\(cjk.map(\.width)))")
    let box = SubtitleLineBoxes.box(for: chinese, style: wrapStyle(), layout: nil, canvas: CGSize(width: 1920, height: 1080))
    check(box?.lineCount == 1 && (box?.rect.width ?? 0) > 1760.0 / 1920, "wrap rules: its box is one row and wider than the frame (got \(String(describing: box)))")
    check(lines(chineseSpaced, style: wrapStyle()).count == 2, "wrap rules: Chinese with spaces wraps at the spaces")
}

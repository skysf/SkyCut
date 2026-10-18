import AppKit
import SrtFlowCore

// 预览和成片在同一个地方折行（2026-10-15，docs/bugfixes/2026-10-15-subtitle-preview-wraps-greedily.md）：一句放不进一行的字幕，
// 以前预览让 SwiftUI 的 Text 自己折 —— 贪心，第一行填满、第二行剩一点（真机量到第一行 x 0.058–0.941）；成片是 libass 的 WrapStyle 0，
// 两行摊匀（0.184–0.815）。位置自检（PositionChecks.swift）的两行样本都带显式换行，自动折行从没量过，所以一直绿。
// 现在折行点只有 SubtitleLineWrap 一份（照 libass 0.17 的 wrap_lines_naive + wrap_lines_rebalance + trim_whitespace port），
// 预览一行一个 Text、只画算好的那一行；烧录把同一份折行点写成 \N、不让 libass 自己折（WrapStyle 2，BurnInWorkspace.prewrapped）——
// libass 只在 ASCII 空格处折，没有空格的长中文句以前成片整行溢出到画面两边，2026-10-15 用户定烧录也要折、标点避头尾
// （docs/bugfixes/2026-10-15-chinese-subtitles-overflow-without-spaces.md）；2026-10-18 起中日文只在词和词之间折、句中的空格和标点后面优先
// （SubtitleCJKRows，docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md）。这里：
// 1. 几种放不进一行的句子（两行 / 三行 / 五行、中英混排、很长的单词、布局覆盖左右不对称、9:16、左 / 右对齐、逐词高亮放大、两个空格、
//    带换行；没有空格的中文、带标点的中文、中英文连着写、中文 + 高亮放大、带空格的韩文），预览离屏渲一张、真烧一帧，按墨迹的空白行
//    切成几行，比**行数**和**每一行**的左右沿（容差 6 px，1080p；折在别处至少差一个字、几十 px）。日文只钉纯算的规矩、不真烧：没下载苹方的
//    机器（CI）上假名的回退字体预览比成片宽约 2.5%（第一次上 CI 两行各差 17 px），是字的大小那一头的事、另案。
// 2. 预览每一行的墨迹宽要和 SubtitleLineWrap 算的步进宽对得上（差一个词就红）—— 管的是叠层按行切 piece 没切错。
// 3. 钉几条折行的规矩本身（不烧、纯算）：100 号五行的每一行是哪几个字（「二分最小宽度」那种算法在这句上会折在别处）；行首行尾的空格
//    不进行；换行符各自成段；亮着的词放大会把那一行变宽；中文在词和词之间折、两行差不多宽、行首不是「，」行尾不是「（」、日文的长音不在行首；
//    L16 测试员的几句（「快手」「以及」「Nano Banana」「GPT Image」「5分钟」各种宽度下都不拆、句中的空格是首选的断点）；
//    韩文只在空格处折（没有空格就不折）；一个比画面宽的英文单词照旧溢出；`SubtitleLineBoxes` 的框和它同几行；烧录的 ASS 是 WrapStyle 2、
//    折行点写成 \N、亮着的词的位置换算到了新的字里（跨行的词拆成两截）。
// 编法见 scripts/check-subtitle-burn-size.sh。不管什么：字的大小（main.swift）、竖向位置（PositionChecks.swift）、阴影（ShadowChecks.swift）。

/// 预览和成片每一行的左右沿最多差这么多像素（1080p 画布）：折在别处至少差一个字、几十 px；回退字体（冬青黑体、Apple SD Gothic Neo）的步进
/// Core Text 和 libass 各自取整，1300 px 的一行累积差 3–5 px。
private let wrapTolerance = 6.0

private struct WrapCase {
    var name: String
    var text: String
    var style: BurnInStyle
    var layout: SubtitleLayout? = nil
    var canvas = CGSize(width: 1920, height: 1080)
    var highlights: [SubtitleTextRange] = []
    var highlight: SubtitleWordHighlight? = nil
    /// 这句该折成几行（样本本身要真的折了才算量到）。nil = 至少两行、具体几行看中文回退到哪一款字体（本机苹方、CI 没下载苹方就是
    /// 冬青黑体，字宽差两成），只要求预览、成片、SubtitleLineWrap 三处一样。
    var rows: Int?
}

private let reported = "This is a much longer subtitle line that goes on and on so that it has to wrap onto a second line at the bottom"
private let threeRows = "When the expedition finally reached the edge of the ice shelf, the penguins had already gathered in their thousands, "
    + "waiting for the long polar night to lift and for the first light of spring"
private let mixed = "南极的冰山 and the penguins 在风里 walking slowly across the ice 一望无际 while the wind keeps blowing"
private let longWords = "Supercalifragilisticexpialidocious antidisestablishmentarianism pneumonoultramicroscopicsilicovolcanoconiosis "
    + "floccinaucinihilipilification honorificabilitudinitatibus"
private let chinese = "南极的冰山一望无际企鹅成群结队地站在风里等待漫长的极夜过去等待春天第一缕阳光照在冰盖上然后再等一个夏天和一个秋天才回到海里去"
private let chineseSpaced = "南极的冰山一望无际 企鹅成群结队地站在风里 等待漫长的极夜过去 等待春天第一缕阳光照在冰盖上 然后再等一个夏天"
private let chinesePunctuated = "南极的冰山一望无际，企鹅成群结队地站在风里，等待漫长的极夜过去。等待春天第一缕阳光照在冰盖上，然后再等一个夏天和一个秋天才回到海里去。"
private let chineseEnglish = "南极的冰山一望无际Penguins站在风里等待the long polar night过去等待春天第一缕阳光照在冰盖上然后再等一个夏天和一个秋天"
private let japanese = "南極の氷山はどこまでも続きペンギンたちは風の中に群れをなして立ち長い極夜が明けるのを待ちそして春の最初の光が氷床を照らすのを待っている"
private let korean = "남극의 빙산은 끝없이 펼쳐져 있고 펭귄들은 바람 속에 무리를 지어 서서 긴 극야가 지나가기를 기다리고 봄의 첫 햇살이 빙상을 비추기를 기다린다"
private let koreanUnspaced = korean.replacingOccurrences(of: " ", with: "")
private let oneWord = "Donaudampfschifffahrtselektrizitätenhauptbetriebswerkbauunterbeamtengesellschaft"
/// L16 课程测试工程里的一句（2026-10-18 测试员：「GPT / Image」被拆开）。
private let l16Names = "包括 Google 的 Nano Banana、OpenAI 的 GPT Image 以及字节跳动的 Seedream"

/// 默认样式（Helvetica 粗体 56 底部居中）换个字体 / 对齐、去掉描边（描边 3 的那一种单独一个用例）。
private func wrapStyle(font: String = "Helvetica", position: SubtitlePosition = .bottomCenter, outline: Double = 0, letterSpacing: Double = 0) -> BurnInStyle {
    var style = BurnInStyle.default
    style.fontName = font
    style.outlineWidth = outline
    style.position = position
    style.letterSpacing = letterSpacing
    return style
}

/// 100 号、不加粗、正中（字大，差一点也量得出来）。
private func hundred(_ font: String) -> BurnInStyle {
    BurnInStyle(name: "check", fontName: font, fontSize: 100, bold: false, outlineWidth: 0, position: .middleCenter)
}

private let wrapWord = (reported as NSString).range(of: "wrap")
private let nightWord = (chinese as NSString).range(of: "极夜")
private let wrapYellow = SubtitleWordHighlight(color: .yellow, scale: 1.2)
private let wrapCases: [WrapCase] = [
    WrapCase(name: "reported sentence", text: reported, style: wrapStyle(), rows: 2),
    WrapCase(name: "reported sentence, outline 3", text: reported, style: BurnInStyle.default, rows: 2),
    WrapCase(name: "three rows", text: threeRows, style: wrapStyle(), rows: 3),
    WrapCase(name: "three rows, bottom left", text: threeRows, style: wrapStyle(position: .bottomLeft), rows: 3),
    WrapCase(name: "three rows, top right", text: threeRows, style: wrapStyle(position: .topRight), rows: 3),
    WrapCase(name: "five rows at 100", text: threeRows, style: hundred("Helvetica"), rows: 5),
    WrapCase(name: "mixed Chinese and English", text: mixed, style: wrapStyle(), rows: 2),
    WrapCase(name: "mixed, Hiragino", text: mixed, style: wrapStyle(font: "Hiragino Sans GB"), rows: 2),
    WrapCase(name: "very long words", text: longWords, style: wrapStyle(), rows: 3),
    WrapCase(name: "Chinese without spaces wraps between words", text: chinese, style: wrapStyle(), rows: nil),
    WrapCase(name: "L16: names and a list in a Chinese line, Hiragino", text: l16Names, style: wrapStyle(font: "Hiragino Sans GB"), rows: 2),
    WrapCase(name: "Chinese, Hiragino", text: chinese, style: wrapStyle(font: "Hiragino Sans GB"), rows: 2),
    WrapCase(name: "Chinese, four rows at 100, Hiragino", text: chinese, style: hundred("Hiragino Sans GB"), rows: 4),
    WrapCase(name: "Chinese 9:16, Hiragino", text: chinese, style: wrapStyle(font: "Hiragino Sans GB"), canvas: CGSize(width: 608, height: 1080), rows: 7),
    WrapCase(name: "Chinese with punctuation, Hiragino", text: chinesePunctuated, style: wrapStyle(font: "Hiragino Sans GB"), rows: 2),
    WrapCase(name: "Chinese and English without spaces", text: chineseEnglish, style: wrapStyle(), rows: nil),
    WrapCase(name: "Chinese with spaces", text: chineseSpaced, style: wrapStyle(), rows: nil),
    WrapCase(name: "Chinese with a highlighted word enlarged", text: chinese, style: wrapStyle(),
             highlights: [SubtitleTextRange(location: nightWord.location, length: nightWord.length)], highlight: wrapYellow, rows: nil),
    WrapCase(name: "Korean with spaces", text: korean, style: wrapStyle(), rows: nil),
    WrapCase(name: "dragged layout 500 / 100", text: reported, style: wrapStyle(),
             layout: SubtitleLayout(marginLeft: 500, marginRight: 100, marginBottom: 200), rows: 2),
    WrapCase(name: "9:16", text: reported, style: wrapStyle(), canvas: CGSize(width: 608, height: 1080), rows: 6),
    WrapCase(name: "highlighted word enlarged", text: reported, style: wrapStyle(),
             highlights: [SubtitleTextRange(location: wrapWord.location, length: wrapWord.length)], highlight: wrapYellow, rows: 2),
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
    let usable = SubtitleLineWrap.usableWidth(canvasWidth: item.canvas.width, style: item.style, layout: item.layout, scale: scale)
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
        if let rows = item.rows {
            check(burnedRows.count == rows, "\(label): the burn wraps it into \(burnedRows.count) rows, the sample expects \(rows)")
        } else {
            check(burnedRows.count >= 2, "\(label): the burn should wrap it into at least two rows, got \(burnedRows.count)")
        }
        check(previewRows.count == burnedRows.count,
              "\(label): the preview wraps into \(previewRows.count) rows, burned \(burnedRows.count)")
        for (row, (p, b)) in zip(previewRows, burnedRows).enumerated() {
            check(abs(p.minX - b.minX) <= wrapTolerance && abs(p.maxX - b.maxX) <= wrapTolerance,
                  "\(label): row \(row + 1) spans x \(Int(p.minX))…\(Int(p.maxX)) in the preview, \(Int(b.minX))…\(Int(b.maxX)) burned")
        }
        // 叠层画的每一行就是 SubtitleLineWrap 算的那一行（墨迹比步进窄一点：两头的边距）；比画面还宽的一行（一个超长的单词）
        // 画布把它裁掉了，只能看它是不是真的铺满了整个画面。
        let computed = computedLines(item)
        check(computed.count == previewRows.count, "\(label): SubtitleLineWrap gives \(computed.count) rows, the preview drew \(previewRows.count)")
        let em = item.style.fontSize * (item.layout?.fontScale ?? 1) * item.canvas.height / Double(BurnInStyle.referenceHeight)
        for (row, (p, line)) in zip(previewRows, computed).enumerated() {
            if line.width > item.canvas.width {
                check(p.width >= item.canvas.width - wrapTolerance,
                      "\(label): row \(row + 1) should overflow the whole canvas, the preview drew \(Int(p.width)) of \(Int(item.canvas.width)) px")
            } else {
                // 行首行尾是中日文标点时墨迹比步进窄一截（「。」的墨迹只占格子的左半），放宽一个字号。
                let rowText = (item.text as NSString).substring(with: line.range)
                let punctuated = [rowText.first, rowText.last].contains { $0.map { "，。、！？：；）」』…".contains($0) } ?? false }
                check(abs(p.width - line.width) <= max(8, line.width * 0.01) + (punctuated ? em : 0),
                      "\(label): row \(row + 1) is \(Int(p.width)) px wide in the preview, SubtitleLineWrap says \(Int(line.width))")
            }
        }
    }
    runWrapRuleChecks()
    runPrewrapChecks()
}

private func lines(_ text: String, style: BurnInStyle, maxWidth: Double = 1760, lit: [NSRange] = [], litScale: Double = 1) -> [SubtitleLineWrap.Line] {
    SubtitleLineWrap.lines(of: text, runs: SubtitleFontScale.runs(text, style: style), style: style, fontSize: style.fontSize,
                           letterSpacing: style.letterSpacing, maxWidth: maxWidth, lit: lit, litScale: litScale)
}

private func texts(_ lines: [SubtitleLineWrap.Line], in text: String) -> [String] {
    lines.map { (text as NSString).substring(with: $0.range) }
}

/// 折行的规矩本身（纯算，不烧）。中文的几条用 Hiragino Sans GB（每台 Mac 都有、字宽一样），Helvetica 里的中文回退到哪一款看机器。
private func runWrapRuleChecks() {
    // 100 号五行：每一轮把上一行最后一个词挪下去、只要两行差变小（libass 真烧出来就是这几行）；按「二分最小宽度」折会是别的几行。
    let five = texts(lines(threeRows, style: hundred("Helvetica")), in: threeRows)
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
    // 亮着的词放大，那一行跟着变宽（烧录的 \fscx \fscy 也放大）。
    let lit = lines(reported, style: wrapStyle(), lit: [wrapWord], litScale: 1.2)
    check(lit.count == 2 && lit[1].width > two[1].width + 5, "wrap rules: an enlarged highlighted word widens its row (\(lit.map(\.width)) vs \(two.map(\.width)))")
    // 中文没有空格也折：在词和词之间断、两行摊匀、都不比可用宽度宽。
    let hiragino = wrapStyle(font: "Hiragino Sans GB")
    let cjk = lines(chinese, style: hiragino)
    check(cjk.count == 2 && cjk.allSatisfy { $0.width <= 1760 } && abs(cjk[0].width - cjk[1].width) < 100,
          "wrap rules: Chinese without spaces wraps between words into two rows about as wide (\(cjk.map(\.width)))")
    let four = texts(lines(chinese, style: hundred("Hiragino Sans GB")), in: chinese)
    check(four.count == 4 && rowsKeepWords(four, ["一望无际", "成群结队", "等待", "极夜", "春天", "阳光", "冰盖", "然后", "夏天", "秋天", "海里"]),
          "wrap rules: Chinese at 100 folds into four rows between words, never inside one (got \(four))")
    runL16WrapChecks()
    // 标点避头尾：逗号插在任何位置都不会落到行首，开头的括号不会落到行尾，日文的长音不在行首。
    let characters = Array(chinese)
    var commaAtRowStart = 0, parenAtRowEnd = 0, barAtRowStart = 0
    for k in 1..<characters.count {
        let comma = String(characters[0..<k]) + "，" + String(characters[k...])
        commaAtRowStart += texts(lines(comma, style: hiragino), in: comma).filter { $0.hasPrefix("，") }.count
        let paren = String(characters[0..<k]) + "（" + String(characters[k...])
        parenAtRowEnd += texts(lines(paren, style: hiragino), in: paren).filter { $0.hasSuffix("（") }.count
        let bar = String(characters[0..<k]) + "ー" + String(characters[k...])
        barAtRowStart += texts(lines(bar, style: hiragino), in: bar).filter { $0.hasPrefix("ー") }.count
    }
    check(commaAtRowStart == 0, "wrap rules: a row never starts with a full-width comma (\(commaAtRowStart) rows did)")
    check(parenAtRowEnd == 0, "wrap rules: a row never ends with an opening bracket (\(parenAtRowEnd) rows did)")
    check(barAtRowStart == 0, "wrap rules: a row never starts with the Japanese long-vowel mark (\(barAtRowStart) rows did)")
    // 日文：假名和汉字之间都能折（纯算，不真烧：见文件头）。
    let japaneseRows = texts(lines(japanese, style: wrapStyle()), in: japanese)
    check(japaneseRows.count >= 2 && !japaneseRows.contains { "ぁぃぅぇぉっゃゅょゎァィゥェォッャュョー、。".contains($0.first!) },
          "wrap rules: Japanese wraps between kana and kanji, never starting a row with small kana or punctuation (got \(japaneseRows))")
    let punctuated = texts(lines(chinesePunctuated, style: hiragino), in: chinesePunctuated)
    check(punctuated.count == 2 && punctuated.allSatisfy { !"，。".contains($0.first!) } && punctuated[1].hasSuffix("。"),
          "wrap rules: punctuated Chinese keeps its punctuation at row ends (got \(punctuated))")
    // 中英文连着写：中文和英文之间可以折，英文单词里面不折。
    let mixedRows = texts(lines(chineseEnglish, style: hiragino), in: chineseEnglish)
    check(mixedRows.count == 2 && mixedRows.contains { $0.contains("Penguins") } && mixedRows.contains { $0.contains("the long polar night") },
          "wrap rules: Chinese next to English breaks between them, never inside the English words (got \(mixedRows))")
    // 韩文：词之间有空格，只在空格处折；没有空格就不折（照旧整行溢出）。
    let koreanRows = lines(korean, style: wrapStyle())
    check(koreanRows.count >= 2 && koreanRows.allSatisfy { $0.width <= 1760 }, "wrap rules: Korean with spaces wraps at the spaces (\(koreanRows.count) rows)")
    let koreanOne = lines(koreanUnspaced, style: wrapStyle())
    check(koreanOne.count == 1 && koreanOne[0].width > 1760, "wrap rules: Korean without spaces does not wrap between syllables (\(koreanOne.map(\.width)))")
    // 一个比画面还宽的英文单词照旧不折、溢出；报给 AI 的框也照实比画面宽。
    let word = lines(oneWord, style: wrapStyle())
    check(word.count == 1 && word[0].width > 1760, "wrap rules: one word wider than the frame stays one overflowing row (\(word.map(\.width)))")
    let wordBox = SubtitleLineBoxes.box(for: oneWord, style: wrapStyle(), layout: nil, canvas: CGSize(width: 1920, height: 1080))
    check(wordBox?.lineCount == 1 && (wordBox?.rect.width ?? 0) > 1760.0 / 1920, "wrap rules: its box is one row and wider than the frame (got \(String(describing: wordBox)))")
    // 中文的框：几行就是 SubtitleLineWrap 的几行、不比可用宽度宽。
    let box = SubtitleLineBoxes.box(for: chinese, style: hiragino, layout: nil, canvas: CGSize(width: 1920, height: 1080))
    check(box?.lineCount == cjk.count && (box?.rect.width ?? 1) <= 1760.0 / 1920 + 0.01,
          "wrap rules: the Chinese box has the same rows and stays inside the margins (got \(String(describing: box)))")
}

/// 相邻两行之间没有把这些词拆开（「快|手」「Nano|Banana」：行是去了两头空格的字，按「|」连起来找）。
private func rowsKeepWords(_ rows: [String], _ words: [String]) -> Bool {
    let joined = rows.joined(separator: "|")
    return words.allSatisfy { word in
        word.contains(" ")
            ? !joined.contains(word.replacingOccurrences(of: " ", with: "|"))
            : (1..<word.count).allSatisfy { !joined.contains(String(word.prefix($0)) + "|" + String(word.dropFirst($0))) }
    }
}

/// L16 测试员的几句（2026-10-18，docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md）：字号 56 / 72 / 96、可用宽度 0.4–1 个画面
/// 扫一遍 —— 词和「5分钟」从不拆（以前「快 / 手」「以 / 及」「三个标签 / 页」）；名字（Nano Banana、GPT Image）72 号以内都不拆（96 号、
/// 宽度一半以内时四行放不下，只能拆）；句中的空格（去掉的逗号）是首选的断点。
private func runL16WrapChecks() {
    let sentences = [
        l16Names, "工作区里有三个标签页 图像、视频和音乐", "视频标签页也提供了 多个目前最强的视频模型！",
        "在音乐标签页中 可以生成最长 5分钟的「音乐」吗？", "我们这节课会讲快手和抖音两个平台上的短视频怎么做才能让更多的人看到"
    ]
    let words = ["以及", "快手", "抖音", "视频", "平台", "怎么", "音乐", "标签", "最强", "生成"]
    var broken: [String] = []
    for size in [56.0, 72, 96] {
        var style = wrapStyle(font: "Hiragino Sans GB")
        style.fontSize = size
        for fraction in stride(from: 0.4, through: 1.0001, by: 0.05) {
            for text in sentences {
                let rows = texts(lines(text, style: style, maxWidth: fraction * 1920), in: text)
                let names = size > 72 || rowsKeepWords(rows, ["Nano Banana", "GPT Image"])
                if !rowsKeepWords(rows, words) || rows.contains(where: { $0.hasSuffix("5") }) || !names {
                    broken.append("\(Int(size)) @\(fraction): \(rows)")
                }
            }
        }
    }
    check(broken.isEmpty, "wrap rules: L16 sentences keep their words, 5分钟 and (up to 72) the names together at every width (\(broken.prefix(3)))")
    let hiragino = wrapStyle(font: "Hiragino Sans GB")
    var big = hiragino
    big.fontSize = 72   // 测试工程的字号；宽度挑在一行放不下的地方
    for (text, fraction, expected) in [("工作区里有三个标签页 图像、视频和音乐", 0.5, ["工作区里有三个标签页", "图像、视频和音乐"]),
                                       ("视频标签页也提供了 多个目前最强的视频模型！", 0.6, ["视频标签页也提供了", "多个目前最强的视频模型！"])] {
        let rows = texts(lines(text, style: big, maxWidth: fraction * 1920), in: text)
        check(rows == expected, "wrap rules: the space between Chinese phrases (a removed comma) is where the row breaks (got \(rows))")
    }
    let names = texts(lines(l16Names, style: hiragino, maxWidth: 1760), in: l16Names)
    check(names.count == 2 && names[0].hasSuffix("、"), "wrap rules: the list breaks after its 、, not inside OpenAI 的 GPT Image (got \(names))")
}

/// 烧录写进 ASS 的就是这几行（BurnInWorkspace.prewrapped + assDocument(prewrapped:)，纯算，不烧）。
private func runPrewrapChecks() {
    let style = wrapStyle(font: "Hiragino Sans GB")
    let computed = lines(chinese, style: style)
    guard computed.count == 2 else {
        check(false, "prewrap: the Chinese sample should fold into two rows, got \(computed.count)")
        return
    }
    let secondRow = computed[1].range.location
    // 亮着的词：一个在第二行、一个跨在折行点上（拆成两截，位置都换算到带换行的新字里）。
    let seaWord = (chinese as NSString).range(of: "海里")
    let straddling = NSRange(location: secondRow - 1, length: 2)
    let cue = SubtitleCue(start: 0, end: 5, text: chinese)
    let block = SubtitleRenderBlock(cues: [cue], layout: nil, highlight: wrapYellow,
                                    highlights: [cue.id: [SubtitleTextRange(location: seaWord.location, length: seaWord.length),
                                                          SubtitleTextRange(location: straddling.location, length: straddling.length)]])
    let pre = BurnInWorkspace.prewrapped([block], style: style, aspectRatio: 16.0 / 9)
    let text = pre.first?.cues.first?.text ?? ""
    check(text == texts(computed, in: chinese).joined(separator: "\n"), "prewrap: the cue's text becomes the computed rows joined by line breaks (got \(text))")
    let remapped = Set(pre.first?.highlights[cue.id] ?? [])
    check(remapped == [SubtitleTextRange(location: secondRow - 1, length: 1), SubtitleTextRange(location: secondRow + 1, length: 1),
                       SubtitleTextRange(location: seaWord.location + 1, length: seaWord.length)],
          "prewrap: highlighted words move with the inserted line break, a word straddling it splits in two (got \(remapped.sorted { $0.location < $1.location }))")
    let ass = style.assDocument(blocks: pre, aspectRatio: 16.0 / 9, prewrapped: true)
    check(ass.contains("WrapStyle: 2"), "prewrap: the ASS tells libass not to wrap on its own (WrapStyle 2)")
    let event = ass.split(separator: "\n").first { $0.hasPrefix("Dialogue:") }.map(String.init) ?? ""
    check(event.components(separatedBy: "\\N").count == 2, "prewrap: exactly one \\N in the event (got \(event))")
    if let breakAt = event.range(of: "\\N"), let tag = event.range(of: "海里") {
        check(tag.lowerBound > breakAt.upperBound && event[breakAt.upperBound..<tag.lowerBound].contains("\\1c"),
              "prewrap: the highlighted word on the second row is tagged after the \\N (got \(event))")
    } else {
        check(false, "prewrap: event has the break and the word (got \(event))")
    }
    // 不带高亮、不带换行的事件：没有字的留着不动，自带换行的照样是硬断。
    let empty = SubtitleCue(start: 0, end: 1, text: "   ")
    let kept = BurnInWorkspace.prewrapped([SubtitleRenderBlock(cues: [empty], layout: nil)], style: style, aspectRatio: 16.0 / 9)
    check(kept.first?.cues.first?.text == "   ", "prewrap: an event with no text is left alone")
    let hard = SubtitleCue(start: 0, end: 1, text: "short first line\n" + chinese)
    let hardRows = BurnInWorkspace.prewrapped([SubtitleRenderBlock(cues: [hard], layout: nil)], style: style, aspectRatio: 16.0 / 9)
        .first?.cues.first?.text.components(separatedBy: "\n") ?? []
    check(hardRows.count == 3 && hardRows[0] == "short first line", "prewrap: the user's own line break stays a paragraph of its own (got \(hardRows))")
}

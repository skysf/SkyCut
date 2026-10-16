import CoreText
import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 字幕长什么样（edit_subtitles / burn_subtitles 的 style，方案第 54 条）：参数先全验过；落到工程上只改工程自己的样式、
// 给了位置就收掉拖框的布局、只给字号就把倍率归一；逐词高亮的开关、颜色、倍数；落到一批烧录上时描边 / 底条互换；
// 回给 AI 看的样子；小程序抄的位置词表和 App 对账。编法见 scripts/check-mcp.sh。

func runSubtitleStyleChecks() {
    styleParsing()
    styleOnProject()
    styleForBurnBatch()
}

/// 大多数用例按 16:9 的画布算（max_width 那组自己给 9:16 的）。
private let wideCanvas = CGSize(width: 1920, height: 1080)

private func change(_ object: [String: JSONValue]) throws -> AISubtitleStyleChange? {
    try AISubtitleStyleChange(AIToolArguments(.object(["style": .object(object)])))
}

private func styleParsing() {
    checkEqual(MCPVocabulary.subtitlePositions, AISubtitleStyleChange.positions.map(\.name), "style：小程序的位置词表 = App 认的")
    let full = try? change([
        "position": "top", "margin": 0.1, "size": 72, "color": "#FFD400", "box": "#00000099",
        "highlight": "#00E5FF", "highlight_scale": 1.2
    ])
    checkEqual(full?.position, .topCenter, "style：top 是上面居中")
    checkEqual(full?.margin, 108, "style：margin 按画面高的比例换成 1080 基准像素")
    checkEqual(full?.size, 72, "style：字号")
    checkEqual(full?.box, .some(SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0x99 / 255.0)), "style：底条带透明度")
    checkEqual(full?.highlightScale, 1.2, "style：高亮的放大倍数")
    checkEqual(try? change([:]).map { $0 == AISubtitleStyleChange() }, true, "style：空对象不改任何东西")
    checkThrows("style：认不出的位置报错") { _ = try change(["position": "left"]) }
    checkThrows("style：字号超出 20–140 报错") { _ = try change(["size": 200]) }
    checkThrows("style：描边和底条都给颜色报错（底条代替描边）") { _ = try change(["outline": "#000000", "box": "#00000099"]) }
    checkThrows("style：阴影和底条都给报错（阴影跟描边走）") { _ = try change(["shadow": "#000000B3", "box": "#00000099"]) }
    checkThrows("style：字色不能是 none") { _ = try change(["color": "none"]) }
    checkThrows("style：放大超过 1.3 报错") { _ = try change(["highlight_scale": 2]) }
    checkEqual(try? change(["line_spacing": 1.25])?.lineSpacing, 1.25, "style：行距是一行高度的倍数")
    checkThrows("style：行距不能小于 1（烧录只能加大）") { _ = try change(["line_spacing": 0.9]) }
    checkThrows("style：行距不能超过 2") { _ = try change(["line_spacing": 2.5]) }
    checkThrows("style：style 不是对象报错") { _ = try AISubtitleStyleChange(AIToolArguments(.object(["style": "big"]))) }
    func font(_ name: String, aliases: [String] = []) -> SubtitleFont {
        SubtitleFont(familyName: name, fileURL: URL(fileURLWithPath: "/tmp/\(name).ttf"), supportsChinese: true, aliases: aliases)
    }
    let fonts = [font("Hiragino Sans GB", aliases: ["冬青黑体简体中文"]), font("Helvetica Neue")]
    checkEqual(try? change(["font": "hiragino sans gb"])?.resolvingFont(in: fonts).font, "Hiragino Sans GB", "style：字体名不分大小写、回表里的写法")
    checkThrows("style：烧录用不了的字体报错（苹方这种读不到文件的）") { _ = try change(["font": "PingFang SC"])?.resolvingFont(in: fonts) }
    // 2026-10-06 盲测：用户自己装的苹方族名是「蘋方-簡」，字体文件里还写着「PingFang SC」—— 按哪个名字叫都认，回族名。
    let installed = fonts + [font("蘋方-簡", aliases: ["PingFang SC"])]
    checkEqual(try? change(["font": "PingFang SC"])?.resolvingFont(in: installed).font, "蘋方-簡",
               "style：字体文件里的别名（PingFang SC）也认，回清单里的族名")
    checkEqual(try? change(["font": "pingfang sc"])?.resolvingFont(in: installed).font, "蘋方-簡", "style：别名同样不分大小写")
    checkEqual(try? change(["font": "冬青黑体简体中文"])?.resolvingFont(in: installed).font, "Hiragino Sans GB", "style：中文的别名也认")
    do {
        _ = try change(["font": "Songti SC"])?.resolvingFont(in: installed)
        check(false, "style：清单里没有的字体该报错")
    } catch {
        check("\(error)".contains("蘋方-簡 (PingFang SC)"), "style：报错列出能用的字体时带上英文的别名：\(error)")
    }
    runFontFamilyNameChecks()
}

/// name 表里的族名（FontFamilyNames）：手造一张表（Windows 平台的繁中 / 英文、Mac 平台的 Roman、别的 nameID、看不懂的编码），
/// 再读一款系统字体的真表。
private func runFontFamilyNameChecks() {
    func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    let entries: [(platform: Int, encoding: Int, language: Int, nameID: Int, bytes: [UInt8])] = [
        (3, 1, 0x0404, 1, Array("蘋方-簡".data(using: .utf16BigEndian)!)),
        (3, 1, 0x0409, 1, Array("PingFang SC".data(using: .utf16BigEndian)!)),
        (1, 0, 0, 1, Array("PingFang SC".utf8)),                         // Mac Roman：同一个名字只留一次
        (3, 1, 0x0409, 4, Array("PingFang SC Regular".data(using: .utf16BigEndian)!)),  // 全名不是族名
        (1, 1, 11, 1, [0x82, 0xA0]),                                      // Mac 日文编码：看不懂，跳过
        (3, 1, 0x0409, 16, Array("PingFang".data(using: .utf16BigEndian)!))
    ]
    var records: [UInt8] = []
    var strings: [UInt8] = []
    for entry in entries {
        records += be16(entry.platform) + be16(entry.encoding) + be16(entry.language) + be16(entry.nameID)
            + be16(entry.bytes.count) + be16(strings.count)
        strings += entry.bytes
    }
    let table = Data(be16(0) + be16(entries.count) + be16(6 + records.count) + records + strings)
    checkEqual(FontFamilyNames.names(inNameTable: table), ["蘋方-簡", "PingFang SC", "PingFang"],
               "name 表：族名（1）和印刷族名（16）都读，去重，全名和看不懂的编码跳过")
    checkEqual(FontFamilyNames.names(inNameTable: Data([0, 0, 0, 5])), [], "name 表：残缺的表读不出东西，不崩")
    // 真表：系统自带的冬青黑体，英文族名之外还有中文写的族名。
    let hiragino = CTFontCreateWithName("Hiragino Sans GB" as CFString, 24, nil)
    let real = FontFamilyNames.names(of: hiragino)
    check(real.contains("Hiragino Sans GB") && real.contains { $0.unicodeScalars.contains { $0.value >= 0x4E00 } },
          "name 表：冬青黑体的真表里有英文和中文的族名：\(real)")
}

private func styleOnProject() {
    let appWide = BurnInStyle.default
    var state = TimelineState()
    state.subtitleLayout = SubtitleLayout(marginLeft: 100, marginRight: 100, marginBottom: 40, fontScale: 1.5)
    try? change(["size": 70])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.subtitleStyle(appWide: appWide).fontSize, 70, "工程：给了字号就改工程自己的样式")
    checkEqual(state.subtitleLayout?.fontScale, 1, "工程：只给字号时拖框的布局留着、字号倍率归一（出来就是这个字号）")
    checkEqual(appWide, BurnInStyle.default, "工程：烧录页记住的那套不动")
    try? change(["line_spacing": 1.3])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.subtitleStyle(appWide: appWide).lineSpacing, 1.3, "工程：行距落到工程自己的样式上")
    checkEqual(state.subtitleStyle(appWide: appWide).fontSize, 70, "工程：改行距不动字号")
    checkEqual(AISubtitleStyleChange.describe(state, appWide: appWide, canvas: wideCanvas)["line_spacing"]?.doubleValue, 1.3, "回给 AI：行距")
    try? change(["position": "top", "margin": 0.08])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    check(state.subtitleLayout == nil && state.translationLayout == nil, "工程：给了位置就收掉拖框的布局（它锚定在底部，会盖住位置）")
    checkEqual(state.subtitleStyle(appWide: appWide).position, .topCenter, "工程：位置")
    checkEqual(state.subtitleStyle(appWide: appWide).fontSize, 70, "工程：之前改的字号还在（从此刻用的那套改起）")

    try? change(["highlight": "#00E5FF"])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.subtitleHighlight?.scale, SubtitleWordHighlight.defaultScale, "高亮：打开时默认放大 1.1 倍")
    try? change(["highlight_scale": 1])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.subtitleHighlight, SubtitleWordHighlight(color: SubtitleColor(red: 0, green: 0xE5 / 255.0, blue: 1), scale: 1),
               "高亮：只给倍数时颜色照旧")
    let described = AISubtitleStyleChange.describe(state, appWide: appWide, canvas: wideCanvas)
    checkEqual(described["own_style"], .bool(true), "回给 AI：这个工程用自己的样式")
    checkEqual(described["position"]?.stringValue, "top", "回给 AI：位置")
    checkEqual(described["highlight"]?.stringValue, "#00E5FF", "回给 AI：高亮颜色")
    try? change(["highlight": "none"])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.subtitleHighlight, nil, "高亮：none 关掉")

    try? change(["reset": true])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.projectSubtitleStyle, nil, "工程：reset 回到烧录页的样式")
    try? change(["reset": true, "color": "#FFFFFF", "bold": false])?.apply(to: &state, appWide: appWide, canvas: wideCanvas)
    checkEqual(state.projectSubtitleStyle?.fontSize, appWide.fontSize, "工程：reset 之后再改，从烧录页那套改起")
    checkEqual(state.projectSubtitleStyle?.bold, false, "工程：reset 之后的改动照样生效")
    state.subtitleLayout = SubtitleLayout(marginLeft: 0, marginRight: 0, marginBottom: 200)
    checkEqual(AISubtitleStyleChange.describe(state, appWide: appWide, canvas: wideCanvas)["position"]?.stringValue,
               "dragged in the preview (a custom spot)", "回给 AI：拖过框的说是自己摆的位置")
}

/// max_width：一行最宽占几成 → 左右边距，按画幅换算；回读一致（2026-09-29 婚礼工程 ISSUE-16）。
private func maxWidthChecks() {
    let wide = CGSize(width: 1920, height: 1080), tall = CGSize(width: 1080, height: 1920)
    checkEqual(AISubtitleStyleChange.playResWidth(canvas: wide), 1920, "16:9 的 ASS 画布 1920 宽")
    checkEqual(AISubtitleStyleChange.playResWidth(canvas: tall), 608, "9:16 的 ASS 画布 608 宽（同 assDocument）")
    checkEqual(AISubtitleStyleChange.horizontalMargin(maxWidth: 0.9, canvas: wide), 96, "16:9 上 0.9 → 左右各 96")
    checkEqual(AISubtitleStyleChange.horizontalMargin(maxWidth: 0.9, canvas: tall), 30, "9:16 上 0.9 → 左右各 30")
    checkEqual(AISubtitleStyleChange.maxWidth(marginHorizontal: 80, canvas: wide), 0.92, "默认边距 80 在 16:9 上是 0.92")
    checkEqual(AISubtitleStyleChange.maxWidth(marginHorizontal: 80, canvas: tall), 0.74, "在 9:16 上只有 0.74")
    checkEqual((try? change(["max_width": 0.9]))?.maxWidth, 0.9, "max_width 读进来")
    checkThrows("max_width 超出范围报错") { _ = try change(["max_width": 0.2]) }
    var state = TimelineState()
    state.canvasRatio = .tall9x16
    (try? change(["max_width": 0.9]))?.apply(to: &state, appWide: BurnInStyle.default, canvas: tall)
    checkEqual(state.projectSubtitleStyle?.marginHorizontal, 30, "落到工程样式的左右边距上（9:16）")
    checkEqual(AISubtitleStyleChange.describe(state, appWide: BurnInStyle.default, canvas: tall)["max_width"]?.doubleValue, 0.9, "describe 回读 max_width")
}

private func styleForBurnBatch() {
    maxWidthChecks()
    let base = BurnInStyle.default
    let boxed = (try? change(["box": "#00000099"]))?.applied(to: base)
    checkEqual(boxed?.borderStyle, .box, "烧录一批：给了底条就是底条模式")
    checkEqual(boxed?.outlineWidth, 6, "烧录一批：底条的内边距默认 6")
    let backToOutline = boxed.flatMap { (try? change(["outline": "#000000"]))?.applied(to: $0) }
    checkEqual(backToOutline?.borderStyle, .outline, "烧录一批：给了描边就回到描边")
    checkEqual(backToOutline?.outlineWidth, 3, "烧录一批：从底条回到描边时粗细回到 3（不沿用内边距）")
    checkEqual((try? change(["outline": "none"]))?.applied(to: base).outlineWidth, 0, "烧录一批：outline none = 不描边")
    // 阴影（2026-09-29 验收：纪录片的卡写着「白字加浅阴影」，AI 却没有这个参数）。
    let shadowed = (try? change(["shadow": "#000000B3"]))?.applied(to: base)
    checkEqual(shadowed?.shadowColor, SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0xB3 / 255.0), "阴影：颜色带透明度")
    checkEqual(shadowed?.shadowOffset, 3, "阴影：打开时偏移 3（烧录页「白字阴影」那套）")
    checkEqual(shadowed.flatMap { (try? change(["shadow": "none"]))?.applied(to: $0).shadowOffset }, 0, "阴影：none 关掉")
    checkEqual((try? change(["shadow": true]))?.shadow, .some(AISubtitleStyleChange.defaultShadow), "阴影：写成 true 也认（set_text 的 shadow 是开关）")
    checkEqual((try? change(["shadow": false]))?.shadow, .some(nil), "阴影：false = 不要阴影")
    let unboxed = boxed.flatMap { (try? change(["shadow": "#000000B3"]))?.applied(to: $0) }
    check(unboxed?.borderStyle == .outline && unboxed?.outlineWidth == 3 && unboxed?.shadowOffset == 3,
          "阴影：底条模式里给阴影就回到描边（底条没有阴影，预览和烧录都不画）")
    check((try? change(["shadow": "#000000B3"]))?.changesLook == true, "阴影：算改了样子（工程从此用自己的样式）")
    var state = TimelineState()
    try? change(["shadow": "#00000099"])?.apply(to: &state, appWide: base, canvas: wideCanvas)
    checkEqual(AISubtitleStyleChange.describe(state, appWide: base, canvas: wideCanvas)["shadow"]?.stringValue, "#00000099", "阴影：回给 AI 看得见")
    checkEqual(base, BurnInStyle.default, "烧录一批：烧录页那套不动（值拷贝）")
    check((try? change(["highlight": "#FFFF00"]))?.changesHighlight == true, "烧录一批：高亮看得出来（工具据此拒绝：字幕文件没有词的时间）")
}

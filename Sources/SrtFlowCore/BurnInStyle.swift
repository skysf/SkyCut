import Foundation

/// 与平台无关的 RGBA 颜色，各分量 0…1。App 层负责和 SwiftUI 的 Color 互转。
public struct SubtitleColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.opacity = opacity.clamped01
    }

    public static let white = SubtitleColor(red: 1, green: 1, blue: 1)
    public static let black = SubtitleColor(red: 0, green: 0, blue: 0)
    public static let yellow = SubtitleColor(red: 1, green: 0.85, blue: 0.1)
    public static let clear = SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0)
    public static let translucentBlack = SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0.6)

    /// ASS 的颜色写法是 `&HAABBGGRR`：字节序和 RGB 相反，而且 alpha 是**反的**
    /// —— `00` 完全不透明，`FF` 完全透明。
    public var assValue: String {
        let a = Int(((1 - opacity) * 255).rounded())
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "&H%02X%02X%02X%02X", a, b, g, r)
    }

    /// 解析 `&HAABBGGRR` / `&HBBGGRR` / `16777215` 这几种常见写法，解析不了返回 nil。
    public static func fromASS(_ raw: String) -> SubtitleColor? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("&h") { text = String(text.dropFirst(2)) }
        text = text.replacingOccurrences(of: "&", with: "")
        guard !text.isEmpty else { return nil }

        let value: UInt32?
        if text.allSatisfy({ $0.isHexDigit }) {
            value = UInt32(text, radix: 16)
        } else {
            value = UInt32(text)
        }
        guard let bits = value else { return nil }

        let b = Double((bits >> 16) & 0xFF) / 255
        let g = Double((bits >> 8) & 0xFF) / 255
        let r = Double(bits & 0xFF) / 255
        let a = text.count > 6 ? 1 - Double((bits >> 24) & 0xFF) / 255 : 1
        return SubtitleColor(red: r, green: g, blue: b, opacity: a)
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

/// 字幕在画面上的九个位置，对应 ASS 的小键盘式 Alignment 取值。
public enum SubtitlePosition: Int, CaseIterable, Codable, Sendable {
    case bottomLeft = 1, bottomCenter = 2, bottomRight = 3
    case middleLeft = 4, middleCenter = 5, middleRight = 6
    case topLeft = 7, topCenter = 8, topRight = 9

    public var assAlignment: Int { rawValue }

    /// 0 = 左，1 = 中，2 = 右
    public var column: Int { (rawValue - 1) % 3 }
    /// 0 = 下，1 = 中，2 = 上
    public var row: Int { (rawValue - 1) / 3 }

    public var isVerticallyCentered: Bool { row == 1 }
}

/// 描边样式：描边+阴影，还是整条半透明底框。
public enum SubtitleBorderStyle: Int, CaseIterable, Codable, Sendable {
    /// ASS BorderStyle 1：描边 + 投影。
    case outline = 1
    /// ASS BorderStyle 3：文字后面垫一块不透明/半透明底框。
    ///
    /// 注意 libass（以及 VSFilter）在这个模式下**用 OutlineColour 画底框**、
    /// 用 Outline 当底框的内边距，BackColour 仍然只管投影。所以
    /// `BurnInStyle.outlineColor` / `outlineWidth` 在这个模式下的含义会变成
    /// 「底框颜色」和「底框内边距」，界面上的文案也要跟着换。
    case box = 3

    /// 这个模式下 `outlineColor` 表示底框颜色而不是描边颜色。
    public var usesOutlineColorAsBox: Bool { self == .box }
}

/// 烧进画面的字幕样式。
///
/// 所有尺寸（字号、描边、边距）都以 **1080p 为基准**：生成的 ASS 里
/// `PlayResY` 固定写 1080，libass 会把这块虚拟画布等比缩放到实际分辨率，
/// 因此同一套样式在 720p 和 4K 上看起来占画面的比例完全一致。
public struct BurnInStyle: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var fillColor: SubtitleColor
    public var outlineColor: SubtitleColor
    public var outlineWidth: Double
    /// BorderStyle 为 .outline 时是投影颜色，为 .box 时是底框颜色。
    public var shadowColor: SubtitleColor
    public var shadowOffset: Double
    public var borderStyle: SubtitleBorderStyle
    public var position: SubtitlePosition
    /// 到画面下（或上）边缘的距离，1080p 基准像素。
    public var marginVertical: Int
    public var marginHorizontal: Int
    public var letterSpacing: Double
    /// 行距：两行之间的距离是一行高度（= 字号，libass 的口径）的多少倍，1 = libass 本来的行距。**只能加大**（`lineSpacingRange` 从 1 起）：
    /// ASS 没有行距这一项，烧录是在两行之间垫一行很矮的空行（`lineSpacer`），收紧做不到。预览的行间距、AI 读的框、烧录的垫片同一个数。
    /// 2026-10-16 加：圆体（Yuanti SC）的 win 量度只有 1.008 em，字形几乎占满整行，两行挨在一起；老文件缺键读 1。
    public var lineSpacing: Double
    /// 是否是内置预设。内置的不可删除、不可覆盖。
    public var isBuiltIn: Bool

    /// 生成 ASS 用的虚拟画布高度。
    public static let referenceHeight = 1080

    /// ASS 的虚拟画布（PlayResX / PlayResY）：1080 高，宽按视频的宽高比取偶数（免得出现 1706.67 这种不整的画布宽）；
    /// 宽高比不像样就当 16:9。预览和 AI 读的框算「一行最宽到哪」也按它（`SubtitleLineBoxes.referenceBox`、`BurnInWorkspace.prewrapped`），
    /// 和写进 ASS 的是同一个数。
    public static func playResolution(aspectRatio: Double) -> (width: Int, height: Int) {
        let safeAspect = aspectRatio.isFinite && aspectRatio > 0.1 ? aspectRatio : 16.0 / 9.0
        return (max(2, Int((Double(referenceHeight) * safeAspect / 2).rounded()) * 2), referenceHeight)
    }

    public static let fontSizeRange = 20.0...140.0
    public static let outlineWidthRange = 0.0...12.0
    public static let shadowOffsetRange = 0.0...12.0
    public static let marginRange = 0...400
    public static let lineSpacingRange = 1.0...2.0

    public init(
        id: UUID = UUID(),
        name: String,
        fontName: String = "Helvetica",
        fontSize: Double = 56,
        bold: Bool = true,
        italic: Bool = false,
        fillColor: SubtitleColor = .white,
        outlineColor: SubtitleColor = .black,
        outlineWidth: Double = 3,
        shadowColor: SubtitleColor = .clear,
        shadowOffset: Double = 0,
        borderStyle: SubtitleBorderStyle = .outline,
        position: SubtitlePosition = .bottomCenter,
        marginVertical: Int = 60,
        marginHorizontal: Int = 80,
        letterSpacing: Double = 0,
        lineSpacing: Double = 1,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.fillColor = fillColor
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.shadowColor = shadowColor
        self.shadowOffset = shadowOffset
        self.borderStyle = borderStyle
        self.position = position
        self.marginVertical = marginVertical
        self.marginHorizontal = marginHorizontal
        self.letterSpacing = letterSpacing
        self.lineSpacing = min(max(lineSpacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - 存盘

    private enum CodingKeys: String, CodingKey {
        case id, name, fontName, fontSize, bold, italic, fillColor, outlineColor, outlineWidth, shadowColor, shadowOffset
        case borderStyle, position, marginVertical, marginHorizontal, letterSpacing, lineSpacing, isBuiltIn
    }

    /// 老文件、老预设（烧录页记住的、工程里的 `projectSubtitleStyle`）没有 `lineSpacing` 键：读成 1，就是以前的样子；超出范围的夹回来。
    /// 别的键照旧必须有。写盘用合成的 `encode(to:)`，老版本读到不认识的键忽略 —— 两个方向都宽容，工程文件不为它 +1 版本。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSize = try c.decode(Double.self, forKey: .fontSize)
        bold = try c.decode(Bool.self, forKey: .bold)
        italic = try c.decode(Bool.self, forKey: .italic)
        fillColor = try c.decode(SubtitleColor.self, forKey: .fillColor)
        outlineColor = try c.decode(SubtitleColor.self, forKey: .outlineColor)
        outlineWidth = try c.decode(Double.self, forKey: .outlineWidth)
        shadowColor = try c.decode(SubtitleColor.self, forKey: .shadowColor)
        shadowOffset = try c.decode(Double.self, forKey: .shadowOffset)
        borderStyle = try c.decode(SubtitleBorderStyle.self, forKey: .borderStyle)
        position = try c.decode(SubtitlePosition.self, forKey: .position)
        marginVertical = try c.decode(Int.self, forKey: .marginVertical)
        marginHorizontal = try c.decode(Int.self, forKey: .marginHorizontal)
        letterSpacing = try c.decode(Double.self, forKey: .letterSpacing)
        let spacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1
        lineSpacing = min(max(spacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
    }

    // MARK: - 内置预设

    /// ASS 样式表里用的名字。所有字幕条目都指到这一个样式上，
    /// 保证界面上调的东西一定生效，不会被源文件自带的样式盖掉。
    public static let assStyleName = "SrtFlow"

    public static let builtInPresets: [BurnInStyle] = [
        BurnInStyle(
            id: UUID(uuidString: "5B1E0001-0000-4000-A000-000000000001")!,
            name: "White text, black outline",
            fontSize: 56, bold: true,
            fillColor: .white, outlineColor: .black, outlineWidth: 3,
            isBuiltIn: true
        ),
        BurnInStyle(
            id: UUID(uuidString: "5B1E0002-0000-4000-A000-000000000002")!,
            name: "Black text, white outline",
            fontSize: 56, bold: true,
            fillColor: .black, outlineColor: .white, outlineWidth: 3,
            isBuiltIn: true
        ),
        BurnInStyle(
            id: UUID(uuidString: "5B1E0003-0000-4000-A000-000000000003")!,
            name: "Yellow text, black outline",
            fontSize: 56, bold: true,
            fillColor: .yellow, outlineColor: .black, outlineWidth: 3,
            isBuiltIn: true
        ),
        BurnInStyle(
            id: UUID(uuidString: "5B1E0004-0000-4000-A000-000000000004")!,
            name: "White text, drop shadow",
            fontSize: 56, bold: true,
            fillColor: .white, outlineColor: .black, outlineWidth: 1.5,
            shadowColor: SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0.75), shadowOffset: 3,
            isBuiltIn: true
        ),
        BurnInStyle(
            id: UUID(uuidString: "5B1E0005-0000-4000-A000-000000000005")!,
            name: "White text on translucent bar",
            fontSize: 52, bold: false,
            // .box 模式下 outlineColor 是底框颜色、outlineWidth 是内边距。
            fillColor: .white, outlineColor: .translucentBlack, outlineWidth: 6,
            shadowColor: .clear, shadowOffset: 0,
            borderStyle: .box,
            isBuiltIn: true
        )
    ]

    public static var `default`: BurnInStyle { builtInPresets[0] }

    // MARK: - 转成 ASS

    /// 转成 `SubtitleStyle`（也就是 ASS 样式表里的一行）。
    public var assStyle: SubtitleStyle {
        SubtitleStyle(
            name: Self.assStyleName,
            fontName: fontName,
            fontSize: fontSize,
            primaryColour: fillColor.assValue,
            // SecondaryColour 只在卡拉 OK 特效里用得到，跟主色一致即可。
            secondaryColour: fillColor.assValue,
            outlineColour: outlineColor.assValue,
            backColour: shadowColor.assValue,
            bold: bold,
            italic: italic,
            underline: false,
            strikeOut: false,
            scaleX: 100,
            scaleY: 100,
            spacing: letterSpacing,
            angle: 0,
            borderStyle: borderStyle.rawValue,
            outline: outlineWidth,
            shadow: shadowOffset,
            alignment: position.assAlignment,
            marginL: marginHorizontal,
            marginR: marginHorizontal,
            marginV: marginVertical,
            encoding: 1
        )
    }

    /// 生成可以直接喂给 `subtitles` 滤镜的完整 ASS 文本（一块字幕，烧字幕页和老调用方用）。
    ///
    /// - Parameters:
    ///   - cues: 字幕条目。
    ///   - aspectRatio: 视频宽高比，用来算虚拟画布的宽度。
    ///   - title: 写进 Script Info 的标题。
    ///   - layout: 工程级布局覆盖（视频编辑器的拖框产物）；nil = 全局样式原样。
    public func assDocument(
        cues: [SubtitleCue],
        aspectRatio: Double,
        title: String = "SrtFlow",
        layout: SubtitleLayout? = nil
    ) -> String {
        assDocument(blocks: [SubtitleRenderBlock(cues: cues, layout: layout)], aspectRatio: aspectRatio, title: title)
    }

    /// 几块字幕各自一个样式（各自的布局）的 ASS 文本：视频编辑器里原文、译文分开摆时是两块
    /// （SubtitleRenderBlocks.swift）。第 i 块的事件放在 Layer i —— libass 只让同一层的事件互相避让，
    /// 分开摆的两块哪怕挨着也不互相推开，和预览一致。
    /// `fontOverrides`：一句字里哪几截要点名字体（烧录时 App 给：这台 Mac 上 libass 找不到回退字体的字，SubtitleASSText）；
    /// 导出字幕文件不给（点名的是这台机器的替补字体，不该写进给别人用的文件）。
    /// `prewrapped`：每句的折行点已经由 App 算好写成了换行（`BurnInWorkspace.prewrapped`，和预览同一份 `SubtitleLineWrap`），
    /// libass 不许再自己折（WrapStyle 2）—— 它只会在 ASCII 空格处折，没有空格的中文整行溢出（2026-10-15）。false = 交给 libass 的 WrapStyle 0。
    public func assDocument(
        blocks: [SubtitleRenderBlock],
        aspectRatio: Double,
        title: String = "SrtFlow",
        fontOverrides: (String) -> [SubtitleFontOverride] = { _ in [] },
        prewrapped: Bool = false
    ) -> String {
        let (width, height) = Self.playResolution(aspectRatio: aspectRatio)

        var styles: [SubtitleStyle] = []
        var events: [SubtitleCue] = []
        for (index, block) in blocks.enumerated() {
            var style = assStyle(layout: block.layout)
            // 第一块沿用老名字：只有一块时产物和以前逐字一样。
            style.name = index == 0 ? Self.assStyleName : "\(Self.assStyleName)\(index + 1)"
            styles.append(style)
            events += block.cues.map { cue in
                var copy = cue
                // 统一指到我们的样式上，并去掉源文件里的 {\...} 覆盖标签和
                // 单条边距，否则界面上的设置会被局部覆盖掉。
                copy.styleName = style.name
                // 只有一块时不动原来的 Layer（外挂 ASS 自带的层照旧），产物和以前逐字一样。
                if blocks.count > 1 { copy.layer = index }
                let plain = SubtitleSerializer.plainText(cue.text)
                // 逐词高亮（此刻正在说的词换色、放大，预览按同一份位置画）和点名字体一起写（SubtitleASSText.swift）。
                copy.text = SubtitleASSText.text(
                    plain, highlight: block.highlight, lit: block.highlights[cue.id] ?? [], fonts: fontOverrides(plain)
                )
                // 行距：两行之间垫一行很矮的空行（只在烧录：折行点是 App 自己写的 `\N`）。
                if prewrapped, let spacer = Self.lineSpacer(fontSize: style.fontSize, lineSpacing: lineSpacing) {
                    copy.text = copy.text.replacingOccurrences(of: "\\N", with: "\\N" + spacer + "\\N")
                }
                copy.marginL = nil
                copy.marginR = nil
                copy.marginV = nil
                copy.effect = ""
                copy.rawOverride = nil
                return copy
            }
        }
        var doc = SubtitleDocumentModel(
            cues: events,
            styles: styles.isEmpty ? [assStyle(layout: nil)] : styles,
            format: .ass,
            title: title
        )
        doc.scriptInfo = [
            "Title": title,
            "ScriptType": "v4.00+",
            // 2 = 不自动折行、只认写好的 \N（折行点 App 算好了）；0 = libass 自己摊匀折（它只在 ASCII 空格处折）。
            "WrapStyle": prewrapped ? "2" : "0",
            // 让描边和投影跟着画布一起缩放，不然 4K 上描边会细得看不见。
            "ScaledBorderAndShadow": "yes",
            "PlayResX": String(width),
            "PlayResY": String(height),
            "YCbCr Matrix": "None"
        ]
        return SubtitleSerializer.serialize(doc, format: .ass)
    }

    /// 行距的垫片：两行之间插一行只有一个不断行空格（`\h`）的空行，字号是多出来的那一截 —— libass 给一行的高度就是当时生效的字号，
    /// 所以行距正好多 `(lineSpacing − 1) × 字号` 个画布像素（2026-10-16 拿仓库的 ffmpeg 真烧量过：垫 30 多 30、垫 60 多 60；真的空行
    /// 只多一半、普通空格多出一整行，都不能用），完事把字号换回这一块样式的字号（高亮用 `\fscx` / `\fscy`、点名字体用 `\fn`，都不碰
    /// `\fs`，所以换回去的永远是样式的字号）。`fontSize` 是这一块 ASS 样式里的字号（布局的倍率已经乘进去）。1 或者差不到半个像素不垫。
    public static func lineSpacer(fontSize: Double, lineSpacing: Double) -> String? {
        let extra = (lineSpacing - 1) * fontSize
        guard extra >= 0.5 else { return nil }
        return "{\\fs" + assNumber(extra) + "}\\h{\\fs" + assNumber(fontSize) + "}"
    }

    /// ASS 里的数：最多两位小数，去掉末尾的零（`56`、`16.8`、`25.2`）。
    public static func assNumber(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

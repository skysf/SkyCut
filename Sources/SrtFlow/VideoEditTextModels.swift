import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 文字标注
//
// 产品口径见 docs/architecture/text-overlays.md。三句话概括：
//
// 1. 文字是**浮在画面之上的标注**，不是视频轨上的一段 —— 和形状同一族，
//    叠放次序固定为「剪辑 → 形状 → 文字 → 字幕」。
// 2. 位置、框宽都是**画布归一化**（0…1），字号等像素量按 **1080p 基准**；
//    于是同一份数据在预览的小画布和导出的大画布上算出同样的版面。
// 3. 画面上拖出来的位置永远是**动画播完的落点**（基准位），动画是相对它的
//    偏移 —— 否则动画一跑选中框就跟着飞，根本拖不住。第二刀加动画时，
//    这条是不变量。

/// 画面上的一段文字。
struct TextOverlay: Identifiable, Hashable, Sendable {
    let id: UUID

    /// 文字内容。可以带换行符 —— 手动换行与自动折行叠加生效。
    var text: String

    var timelineStart: Double
    var duration: Double

    /// 排版框中心在画布上的归一化位置。文字块**以中心对齐到这一点**
    /// （不是左上角）：改字号或改文案时文字向两边生长，用户摆好的居中不会跑。
    var centerX: Double
    var centerY: Double
    /// 自动折行的框宽，占画布宽度的比例。超出这个宽度才折行。
    var boxWidth: Double
    /// 顺时针旋转角（度），绕排版框中心。
    var rotationDegrees: Double

    var style: TextStyle
    /// 入场 / 出场 / 强调。动画是**相对基准位置的偏移**，不改 `centerX/centerY`
    /// —— 画面上拖出来的位置永远是动画播完的落点。
    var animation: TextAnimation
    /// 数字滚动。非 nil 时**内容由它算**，`text` 不再显示 ——
    /// 做成可选字段而不是另一个模型，于是数字白捡整套样式、动画和摆放能力。
    var number: NumberRoll?

    init(
        id: UUID = UUID(),
        text: String = "",
        timelineStart: Double,
        duration: Double = TextOverlay.defaultDuration,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        boxWidth: Double = 0.8,
        rotationDegrees: Double = 0,
        style: TextStyle = .default,
        animation: TextAnimation = .default,
        number: NumberRoll? = nil,
        row: Int = 0
    ) {
        self.id = id
        self.text = text
        self.timelineStart = timelineStart
        self.duration = duration
        self.centerX = centerX
        self.centerY = centerY
        self.boxWidth = boxWidth
        self.rotationDegrees = rotationDegrees
        self.style = style
        self.animation = animation
        self.number = number
        self.row = row
    }

    /// 时间线上在哪一行（0 = 最下面那条文字行，紧挨形状行；越大越靠上）。
    /// **行序就是画面上的叠放序**：行号大的画在上面（VideoEditTextRows.swift）。
    /// 进模型、存盘（v21）；老工程没有这个键，载入时按当年的自动排布补上
    ///（`TimelineState.normalizeTextRows`）。
    var row: Int
    /// 读盘时没有 `row` 键的标记，只在载入到 `normalizeTextRows` 之间短暂存在。
    static let unassignedRow = -1
    /// 单个藏起来（选中按 V，2026-09-26 用户拍板）：时间线上灰显、仍可编辑、照样占着自己那一行，
    /// 预览和成片里都没有。和剪辑的 `EditClip.isHidden` 同一条语义（docs/architecture/clip-visibility.md）。
    /// v22 字段，按需写键。
    var isHidden = false
    /// 用户打在这一块上的标记（离块起点多少秒；裁头时留在原来的时间线时刻）。只影响编辑期的显示，
    /// 不进合成和导出。类型与读写见 VideoEditClipMarker.swift。v28 字段，按需写键。
    var markers: [ClipMarker] = []
    /// 动效预设放上去的那一组里的哪一块（下面 `MotionPresetTag`）。nil = 普通文字。按需写键，不抬格式版本。
    var motionPreset: MotionPresetTag?

    /// 新建时的时长，与形状一致（3 秒）。
    static let defaultDuration = 3.0
    /// 时间线上能拖到的最短时长，与形状的下限同一个数。
    static let minimumDuration = 0.2
    static let boxWidthRange = 0.05...1.0

    var timelineEnd: Double { timelineStart + duration }

    func contains(time: Double) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    /// 完全没字的文字块：画面上不渲染，导出也跳过。
    ///
    /// 不自动删除 —— 新建的第一件事就是「空着等用户打字」，
    /// 顺手删掉它会让刚 Add 出来的东西当场消失。
    /// 数字元件永远有内容（至少是个 0），所以只对纯文字判空。
    var isBlank: Bool {
        guard number == nil else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 这一刻要排版的文字。
    ///
    /// 老虎机取的是**定版串**（滚动只改每一位的轮位，不改排版）；
    /// 数值插值才真的换字符串。`local` 是这段文字自己的时间。
    func resolvedText(local: Double) -> String {
        guard let number else { return text }
        switch number.style {
        case .count: return number.text(for: number.value(local: local))
        case .odometer: return number.settledText
        }
    }

    /// 排版定版用的串：选中框、包络都按它算，免得位数变化时框跳来跳去。
    var settledText: String { number?.settledText ?? text }

    /// 这段内容需要逐帧渲染吗（动画或数字滚动）。
    var needsPerFrameRendering: Bool { !animation.isEmpty || number != nil }

    /// 头部需要逐帧的那一截：入场动画和数字「等待 + 滚动」谁长听谁的。
    ///
    /// 数字滚完之前画面每一帧都在变，哪怕入场动画早就结束了 ——
    /// 只按入场时长切段的话，滚动的后半截会被冻成一张静止图。等待也算在头里：
    /// 等待期间画面虽然不变，但滚动在它之后，只按滚动时长切的话数字会在等待
    /// 结束那一刻被冻住。
    func animatedHead(window: FadeWindow) -> Double {
        max(window.fadeIn, number.map { min($0.settleTime, duration) } ?? 0)
    }

    /// 时间线块上显示的名字。空的时候给个占位，否则块上是一片空白。
    ///
    /// 截断和取首行放在 `summarize` 里，**不能内联回来**：本地化守卫会把
    /// `var displayName: String { … }` 体内的所有字面量都当成待翻译的文案
    /// （它靠属性名认动态 key），换行符和省略号会被误报成缺失文案。
    var displayName: String {
        let trimmed = settledText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n("Empty text") }
        return TextOverlay.summarize(trimmed)
    }

    private static func summarize(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 24 ? String(firstLine.prefix(24)) + "…" : firstLine
    }

    /// 1080p 基准的像素量换算到这块画布上的系数。
    ///
    /// **按高度换算**（与字幕的 `PlayResY` 同一个口径）：按宽度算的话，
    /// 同一套样式在 16:9 和 9:16 之间切换时字号会突变。
    static func pixelScale(canvas: CGSize) -> Double {
        guard canvas.height > 0 else { return 1 }
        return canvas.height / TextStyle.referenceHeight
    }
}

extension TextOverlay {
    /// 把所有数值收进合法区间。**唯一的收口点** ——
    /// `TimelineState.updateTextOverlay` 每次改完都调它，于是画面拖拽、检查器、
    /// 就地编辑三条路不可能各自漏掉一个字段。
    mutating func clampToValidRange() {
        timelineStart = max(0, timelineStart)
        duration = max(TextOverlay.minimumDuration, duration)
        centerX = min(max(centerX, 0), 1)
        centerY = min(max(centerY, 0), 1)
        boxWidth = min(max(boxWidth, TextOverlay.boxWidthRange.lowerBound), TextOverlay.boxWidthRange.upperBound)
        // 收进 (-180, 180]：检查器里的角度框不该出现 720°，而 -10° 比 350° 好读。
        var angle = rotationDegrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle <= -180 { angle += 360 }
        rotationDegrees = angle.isFinite ? angle : 0
        style.clampToValidRange()
        animation.clampToValidRange()
        number?.clampToValidRange()
    }
}

extension TextStyle {
    mutating func clampToValidRange() {
        fontSize = min(max(fontSize, TextStyle.fontSizeRange.lowerBound), TextStyle.fontSizeRange.upperBound)
        lineSpacing = min(max(lineSpacing, TextStyle.lineSpacingRange.lowerBound), TextStyle.lineSpacingRange.upperBound)
        letterSpacing = min(max(letterSpacing, TextStyle.letterSpacingRange.lowerBound), TextStyle.letterSpacingRange.upperBound)
        if var value = stroke {
            value.width = min(max(value.width, TextStroke.widthRange.lowerBound), TextStroke.widthRange.upperBound)
            stroke = value
        }
        if var value = shadow {
            value.offsetX = min(max(value.offsetX, TextShadow.offsetRange.lowerBound), TextShadow.offsetRange.upperBound)
            value.offsetY = min(max(value.offsetY, TextShadow.offsetRange.lowerBound), TextShadow.offsetRange.upperBound)
            value.blur = min(max(value.blur, TextShadow.blurRange.lowerBound), TextShadow.blurRange.upperBound)
            shadow = value
        }
        if var value = background {
            value.cornerRadius = min(max(value.cornerRadius, TextBackground.cornerRadiusRange.lowerBound), TextBackground.cornerRadiusRange.upperBound)
            value.paddingX = min(max(value.paddingX, TextBackground.paddingRange.lowerBound), TextBackground.paddingRange.upperBound)
            value.paddingY = min(max(value.paddingY, TextBackground.paddingRange.lowerBound), TextBackground.paddingRange.upperBound)
            background = value
        }
    }
}

extension TextOverlay: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, text, timelineStart, duration
        case centerX, centerY, boxWidth, rotationDegrees, style, animation, number, row, isHidden, markers
        case motionPreset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            timelineStart: try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? TextOverlay.defaultDuration,
            centerX: try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5,
            centerY: try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5,
            boxWidth: try c.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 0.8,
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            style: try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? .default,
            animation: try c.decodeIfPresent(TextAnimation.self, forKey: .animation) ?? .default,
            number: try c.decodeIfPresent(NumberRoll.self, forKey: .number),
            row: try c.decodeIfPresent(Int.self, forKey: .row) ?? TextOverlay.unassignedRow
        )
        // 缺键 = 没藏（v21 及更早没有这个概念）。
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        // 缺键 = 没打过标记（v27 及更早文字上打不了）。
        markers = try c.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
        // 缺键或读不懂（以后的版本多出来的预设）= 普通文字：字和动画都在自己的字段里，丢的只是「是一组」。
        motionPreset = MotionPresetTag.decode(c, forKey: .motionPreset)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(boxWidth, forKey: .boxWidth)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
        try c.encode(style, forKey: .style)
        // 没设动画的文字不落这个键：一份只用静态文字的工程不该因此被抬进 v12
        //（判据见 VideoEditFormatVersion.swift 的登记清单）。
        if !animation.isEmpty { try c.encode(animation, forKey: .animation) }
        // 同理：不是数字元件的文字不落这个键，免得被抬进 v13。
        try c.encodeIfPresent(number, forKey: .number)
        // 行号无条件落盘：它决定画面上谁压谁，没有「默认就等于没有」这回事（v21）。
        try c.encode(row, forKey: .row)
        // 按需写键：没藏过的文字不落它，免得被抬进 v22。
        if isHidden { try c.encode(isHidden, forKey: .isHidden) }
        // 同上：一枚标记都没有的不落键，免得被抬进 v28。
        if !markers.isEmpty { try c.encode(markers, forKey: .markers) }
        // 按需写键（同形状）。**不抬格式版本**：旧版读不懂就当普通文字，成片一帧不变（同 `rowHeights` 的口径）。
        try c.encodeIfPresent(motionPreset, forKey: .motionPreset)
    }
}

// MARK: - 动效预设的成员标记
//
// 一套动效预设（MCP-45，docs/architecture/motion-presets.md）放上时间线的是**普通的字和形状**，各自的样式、动画都在它们
// 自己的字段里，照常能一块一块地改；这里只记「这一块是哪一组、哪一套、在组里是什么」，换预设、挪落点、标题动了别的跟着走
// 都按它认。文字和形状共用（`ShapeAnnotation.motionPreset`）。

/// 一套现成能拼的动效。rawValue 是 AI 用的名字（set_text 的 `motion_preset`，词表 `MCPVocabulary.motionPresets` 对账）。
enum MotionPresetKind: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    /// 框住再放开：细框顺时针画出来框住名字，随后倒着收走，字留下（样片「盒子框」）。
    case frameReveal = "frame_reveal"
    /// 对焦出字：细字、字距宽，从虚收清进来，出的时候虚掉（样片「对焦」）。
    case focusPull = "focus_pull"
    /// 标题 + 滚动的数字：标题弹出来，下面一条细线画出来，数字像老虎机滚到一个数（样片「两极之间的距离」）。
    case titleCounter = "title_counter"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frameReveal: return "Frame Reveal"
        case .focusPull: return "Focus Pull"
        case .titleCounter: return "Title + Counter"
        }
    }

    var icon: String {
        switch self {
        case .frameReveal: return "rectangle.dashed"
        case .focusPull: return "camera.aperture"
        case .titleCounter: return "textformat.123"
        }
    }
}

/// 一块在组里是什么。
enum MotionPresetRole: String, Hashable, Sendable, Codable {
    /// 主标题（组的锚：它挪了、改了字，别的跟着它走）。
    case title
    /// 标题上面 / 下面的一行小字（FROM、PRESENTS）。
    case smallAbove, smallBelow
    /// 标题下面滚动的数字。
    case counter
    /// 框住标题的长方形、标题下面的细线。
    case frame, rule
}

struct MotionPresetTag: Hashable, Sendable, Codable {
    /// 同一组的几块共用这一个号（粘贴、复制出来的换新号：`TimelinePaste.apply`）。
    var group: UUID
    var preset: MotionPresetKind
    var role: MotionPresetRole

    /// 宽容读：缺键、读不懂（以后多出来的预设 / 角色）都当没有 —— 那一块照样是普通的字或形状。
    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> MotionPresetTag? {
        (try? container.decodeIfPresent(MotionPresetTag.self, forKey: key)) ?? nil
    }

    /// 粘贴 / 复制出来的几块换新组号（`TimelinePaste.apply`，同剪辑的链接组）：同一组在这一批里至少两块，换成同一个新号
    ///（粘出来的一套自成一组，不和原来那套连在一起 —— 不然换预设、挪落点会连原来那套一起动）；只拿到一块的不留标记。
    /// `renamed` 让文字和形状两次调用换成同一个新号。
    static func renew<Member: MotionPresetMember>(
        _ items: inout [Member], pasted: Set<UUID>, counts: [UUID: Int], renamed: inout [UUID: UUID]
    ) {
        for index in items.indices where pasted.contains(items[index].id) {
            guard let tag = items[index].motionPreset else { continue }
            guard (counts[tag.group] ?? 0) >= 2 else {
                items[index].motionPreset = nil
                continue
            }
            let fresh = renamed[tag.group] ?? UUID()
            renamed[tag.group] = fresh
            items[index].motionPreset?.group = fresh
        }
    }

    /// 这一批里每一组有几块（`renew` 的 `counts`）。
    static func counts(_ texts: [TextOverlay], _ shapes: [ShapeAnnotation]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for tag in texts.compactMap(\.motionPreset) + shapes.compactMap(\.motionPreset) { counts[tag.group, default: 0] += 1 }
        return counts
    }
}

/// 能是预设里一块的东西：文字和形状。
protocol MotionPresetMember {
    var id: UUID { get }
    var motionPreset: MotionPresetTag? { get set }
}

extension TextOverlay: MotionPresetMember {}
extension ShapeAnnotation: MotionPresetMember {}

// MARK: - 老工程的自动排布（只剩迁移在用）
//
// 2026-09-24 起行号进模型（`TextOverlay.row`，VideoEditTextRows.swift）。在那之前
// 文字行由时间重叠现算：下面这个贪心只在载入没有 `row` 键的老工程时跑一次，把当年
// 画在屏幕上的那个排布原样变成行号。**别在别处再调它。**

enum TextOverlayStacking {
    /// 给每一段文字算一个层号（0 = 最上面那一行）。
    ///
    /// 贪心：按开始时间排，每段放进**第一条放得下的层**。这样两段不重叠的
    /// 文字会共用一层，只有真重叠了才长出新的一层，行数最少。
    ///
    /// 数组顺序就是 `state.textOverlays` 的顺序，调用方可以直接按下标取用。
    static func levels(for overlays: [TextOverlay]) -> [Int] {
        var levels = [Int](repeating: 0, count: overlays.count)
        // 每一层当前的右端。层号即下标。
        var lineEnds: [Double] = []
        for index in overlays.indices.sorted(by: {
            (overlays[$0].timelineStart, overlays[$0].id.uuidString)
                < (overlays[$1].timelineStart, overlays[$1].id.uuidString)
        }) {
            let overlay = overlays[index]
            // 容差 1ms：紧挨着的两段（前一段结束 = 后一段开始）应当共用一层，
            // 浮点误差不该逼出一条新行。
            if let line = lineEnds.firstIndex(where: { $0 <= overlay.timelineStart + 0.001 }) {
                levels[index] = line
                lineEnds[line] = overlay.timelineEnd
            } else {
                levels[index] = lineEnds.count
                lineEnds.append(overlay.timelineEnd)
            }
        }
        return levels
    }

    /// 文字行一共要占几层。没有文字时是 0（那一行整个不出现）。
    static func levelCount(for overlays: [TextOverlay]) -> Int {
        (levels(for: overlays).max().map { $0 + 1 }) ?? 0
    }
}

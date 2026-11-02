import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - edit_clip 里和画面有关的参数（纯值）
//
// 管什么：fit / focus / follow / crop / region / remove_black_bars / x / y / scale 读成类型，互相冲突的组合
// 当场挡掉（fit 和 x/y/scale 不能一起给、focus 只跟 fit=fill 走、手动裁切和去黑边二选一）。纯值，自检够得着
// （scripts/check-mcp.sh）。
// 不管什么：按这些参数算裁切和摆放（AIFrameFit）、去看画面（AIClipTools）。

/// edit_clip 里和画面有关的那几个参数（读的时候就把互相冲突的组合挡掉）。
struct AIFramingRequest {
    enum Fit: String { case fit, fill }
    /// 铺满时窗对准哪儿：认出来的主体（人脸 → 人 → 字多时对准字 → 显眼的东西，默认）、只对准字（幻灯片、录屏，
    /// 方案第 55 条），或者正中。
    enum Focus: String { case subject, text, center }

    var fit: Fit?
    var focus: Focus = .subject
    /// AI 直接给的点（focus_x / focus_y），给了就不去认主体。
    var focusPoint: CGPoint?
    /// 手动的四边裁切（`crop` 参数）；给了全 0 就是不裁。
    var crop: ClipCrop?
    /// 旋转信息摆正后的源画面矩形（左上原点，归一化），替换旧裁切 / 摆放。
    var region: CGRect?
    /// 抽几帧找黑边、裁掉（找到的黑边当作「可用区域」，fit / fill 在它里面算）。
    var removeBlackBars = false
    var x: Double?
    var y: Double?
    var scale: Double?
    /// 铺满、对准主体时，主体走动大就用位置关键帧跟着走（默认开，第四块）；false = 一个固定的窗。
    var follow = true

    var touchesPicture: Bool {
        fit != nil || crop != nil || region != nil || removeBlackBars || x != nil || y != nil || scale != nil
    }

    init(_ args: AIToolArguments) throws {
        fit = try args.choice("fit", from: ["fit", "fill"]).flatMap(Fit.init(rawValue:))
        x = try args.double("x")
        y = try args.double("y")
        scale = try args.double("scale")
        let namedFocus = try args.choice("focus", from: ["subject", "text", "center"]).flatMap(Focus.init(rawValue:))
        focus = namedFocus ?? .subject
        let focusX = try args.double("focus_x")
        let focusY = try args.double("focus_y")
        try AIEditLimits.require("x", x, in: MCPFramingLimits.center)
        try AIEditLimits.require("y", y, in: MCPFramingLimits.center)
        try AIEditLimits.require("scale", scale, in: MCPFramingLimits.scale)
        try AIEditLimits.require("focus_x", focusX, in: 0...1)
        try AIEditLimits.require("focus_y", focusY, in: 0...1)
        if focusX != nil || focusY != nil {
            focusPoint = CGPoint(x: min(max(focusX ?? 0.5, 0), 1), y: min(max(focusY ?? 0.5, 0), 1))
        }
        if args.has("crop") {
            guard let raw = args.raw["crop"], case .object = raw else {
                throw AIToolError("crop must be an object like {\"left\": 0.1, \"right\": 0.1, \"top\": 0, \"bottom\": 0}.")
            }
            let edges = AIToolArguments(raw)
            for name in ["top", "bottom", "left", "right"] {
                try AIEditLimits.require("crop.\(name)", try edges.double(name), in: 0...ClipCrop.maximumManualInset)
            }
            crop = ClipCrop(
                top: try edges.double("top") ?? 0, bottom: try edges.double("bottom") ?? 0,
                leading: try edges.double("left") ?? 0, trailing: try edges.double("right") ?? 0
            )
        }
        removeBlackBars = try args.bool("remove_black_bars") ?? false
        if removeBlackBars, crop != nil {
            throw AIToolError("Pass either crop or remove_black_bars, not both.")
        }
        if fit != nil, x != nil || y != nil || scale != nil {
            throw AIToolError("Use fit to fill or fit the frame, or x/y/scale to place the picture yourself, not both.")
        }
        if focusPoint != nil || namedFocus != nil, fit != .fill {
            throw AIToolError("focus, focus_x and focus_y only apply with fit=fill.")
        }
        if let wanted = try args.bool("follow") {
            guard fit == .fill else { throw AIToolError("follow only applies with fit=fill.") }
            follow = wanted
        }
        region = try Self.sourceRegion(args)
        if region != nil { fit = fit ?? .fit }
    }

    private static func sourceRegion(_ args: AIToolArguments) throws -> CGRect? {
        guard args.has("region") else { return nil }
        guard let raw = args.raw["region"], case .object = raw else {
            throw AIToolError("region must be {x, y, width, height}: fractions of the upright source picture, from its top-left.")
        }
        let fields = AIToolArguments(raw)
        let rect = CGRect(
            x: try fields.requiredDouble("x"), y: try fields.requiredDouble("y"),
            width: try fields.requiredDouble("width"), height: try fields.requiredDouble("height")
        )
        guard ClipCrop(keeping: rect) != nil else {
            throw AIToolError("region must be inside 0–1: x/y ≥ 0, width/height > 0, x+width ≤ 1 and y+height ≤ 1.")
        }
        let conflicts = ["crop", "remove_black_bars", "focus", "focus_x", "focus_y", "follow", "x", "y", "scale",
                         "rotation", "flip_horizontal", "flip_vertical"].filter(args.has)
        guard conflicts.isEmpty else {
            throw AIToolError("region cannot be combined with \(conflicts.joined(separator: ", ")). Use region with fit=fit (default) or fit=fill.")
        }
        return rect
    }
}

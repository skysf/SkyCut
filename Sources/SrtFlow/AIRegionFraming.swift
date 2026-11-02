import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 显式源矩形取景（纯值）
//
// 管什么：源显示坐标的矩形 → 既有 crop / placement，最小像素和变换冲突校验，以及实际区域 / 变换回报。
// 不管什么：识别主体、改时间线、绘制或导出；铺满的窗和映射只调 AIFrameFit，原生两条渲染管线照旧消费模型。

enum AIRegionFraming {
    static func make(
        _ clip: EditClip, canvas: CGSize, region: CGRect, fill: Bool, clearsKeyframes: Bool = false
    ) throws -> AIFrameFit.Framing {
        guard let display = clip.info?.displaySize, display.width > 0, display.height > 0,
              canvas.width > 0, canvas.height > 0, ClipCrop(keeping: region) != nil else {
            throw AIToolError("region needs a picture with known dimensions and a valid source rectangle.")
        }
        // preferredTransform 是源方向，displaySize 已摆正。用户额外旋转 / 几何入出场会改变固定窗的可见区域，先拒绝。
        let rotated = abs(clip.rotationDegrees) > 0.01
            || (!clearsKeyframes && !(clip.animation?.rotation.isEmpty ?? true))
        let edges = [clip.presetAnimation.entrance, clip.presetAnimation.exit]
        guard !rotated, edges.allSatisfy({ $0 == .none || $0 == .fade }) else {
            throw AIToolError("region needs a fixed upright frame. Remove the clip's rotation and motion entrance/exit first; rotation keyframes can be removed with keyframes=clear.")
        }
        try requirePixels(region, display: display)
        let active = pixelBounds(region, display: display)
        let window = fill
            ? AIFrameFit.fillWindow(display: display, canvas: canvas, active: active, focus: CGPoint(x: active.midX, y: active.midY))
            : active
        try requirePixels(window, display: display)
        let kept = pixelBounds(window, display: display).intersection(active)
        guard let exact = ClipCrop(keeping: kept) else { throw AIToolError("region has no usable source pixels.") }
        let crop: ClipCrop? = exact.isEmpty ? nil : exact
        return fill
            ? AIFrameFit.mapping(clip, canvas: canvas, window: window, crop: crop)
            : AIFrameFit.Framing(crop: crop, placement: nil)
    }

    /// 保留完整请求范围，最多向外取一个源像素；整数裁切和 ffmpeg exact=1 让两条管线用同一组边界。
    private static func pixelBounds(_ region: CGRect, display: CGSize) -> CGRect {
        let left = floor(region.minX * display.width + 1e-9)
        let top = floor(region.minY * display.height + 1e-9)
        let right = min(display.width, ceil(region.maxX * display.width - 1e-9))
        let bottom = min(display.height, ceil(region.maxY * display.height - 1e-9))
        return CGRect(x: left / display.width, y: top / display.height,
                      width: (right - left) / display.width, height: (bottom - top) / display.height)
    }

    private static func requirePixels(_ region: CGRect, display: CGSize) throws {
        guard region.width * display.width >= 2 - 1e-9, region.height * display.height >= 2 - 1e-9 else {
            throw AIToolError("region (and its fit=fill window) must keep at least 2 source pixels in each dimension. Enlarge it or use fit=fit.")
        }
    }

    static func summary(_ clip: EditClip, canvas: CGSize, requested: CGRect? = nil) -> JSONValue {
        let retained = AIFrameFit.region(of: clip.crop)
        let placement = clip.resolvedPlacement(canvas: canvas)
        let target = placement.frame(in: canvas)
        let intersection = target.intersection(CGRect(origin: .zero, size: canvas))
        var object: [String: JSONValue] = [
            "region": rect(retained),
            "transform": [
                "x": number(placement.centerX), "y": number(placement.centerY),
                "width": number(placement.width), "height": number(placement.height),
                "rotation": number(clip.rotationDegrees),
                "opacity": number(clip.opacity),
                "flip_horizontal": .bool(clip.flippedHorizontally), "flip_vertical": .bool(clip.flippedVertically)
            ]
        ]
        if let crop = clip.crop, !crop.isEmpty {
            object["crop"] = ["left": number(crop.leading), "right": number(crop.trailing), "top": number(crop.top), "bottom": number(crop.bottom)]
        }
        if let requested { object["requested_region"] = rect(requested) }
        if let size = clip.info?.displaySize {
            object["source_display_size"] = ["width": number(size.width), "height": number(size.height)]
        }
        // 轴对齐的静态取景才有一扇矩形可见窗；其它编辑入口的旋转 / 动画不给误导性的轴对齐结果。
        let motion = clip.animation ?? ClipAnimation()
        let fixed = motion.centerX.isEmpty && motion.centerY.isEmpty && motion.width.isEmpty && motion.height.isEmpty && motion.rotation.isEmpty
            && !clip.needsPerFrameAnimation
        if abs(clip.rotationDegrees) <= 0.01, fixed,
           !intersection.isNull, target.width > 0, target.height > 0 {
            var x = (intersection.minX - target.minX) / target.width
            var y = (intersection.minY - target.minY) / target.height
            let width = intersection.width / target.width
            let height = intersection.height / target.height
            if clip.flippedHorizontally { x = 1 - x - width }
            if clip.flippedVertically { y = 1 - y - height }
            object["visible_region"] = rect(CGRect(
                x: retained.minX + x * retained.width, y: retained.minY + y * retained.height,
                width: width * retained.width, height: height * retained.height
            ))
        }
        return .object(object)
    }

    private static func rect(_ value: CGRect) -> JSONValue {
        ["x": number(value.minX), "y": number(value.minY), "width": number(value.width), "height": number(value.height)]
    }

    private static func number(_ value: Double) -> JSONValue { .number((value * 1_000_000).rounded() / 1_000_000) }
}

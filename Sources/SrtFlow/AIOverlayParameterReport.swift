import Foundation
import SrtFlowMCPKit

// 文字 / 形状沿用生产模型的自动限幅，只从最终状态读回结果；单项与批量调用同一份反馈。
enum AIOverlayParameterReport {
    static func text(_ raw: JSONValue, overlay: TextOverlay) -> [String: JSONValue] {
        let n = AIParameterReport.number
        let window = overlay.animation.window(span: overlay.duration)
        var values: [String: JSONValue] = [
            "start": n(overlay.timelineStart), "duration": n(overlay.duration), "x": n(overlay.centerX), "y": n(overlay.centerY),
            "box_width": n(overlay.boxWidth), "font_size": n(overlay.style.fontSize), "stroke_width": n(overlay.style.stroke?.width ?? 0),
            "letter_spacing": n(overlay.style.letterSpacing), "rotation": n(overlay.rotationDegrees),
            "animation_in_duration": n(window.fadeIn), "animation_out_duration": n(window.fadeOut),
            "animation_intensity": n(overlay.animation.intensity)
        ]
        if let roll = overlay.number {
            values["number"] = ["from": n(roll.from), "to": n(roll.to), "decimals": n(Double(roll.fractionDigits)),
                                "thousands": .bool(roll.groupsThousands), "prefix": .string(roll.prefix), "suffix": .string(roll.suffix),
                                "style": .string(roll.style.rawValue), "seconds": n(roll.duration), "delay": n(roll.delay), "remove": false]
        } else { values["number"] = ["remove": true] }
        let limits: [String: JSONValue] = [
            "font_size": AIEditLimits.bounds(TextStyle.fontSizeRange, policy: "clamp"),
            "box_width": AIEditLimits.bounds(TextOverlay.boxWidthRange, policy: "clamp"),
            "stroke_width": AIEditLimits.bounds(TextStroke.widthRange, policy: "clamp; zero when disabled"),
            "letter_spacing": AIEditLimits.bounds(TextStyle.letterSpacingRange, policy: "clamp")
        ]
        return report(raw, values: values, limits: limits)
    }

    static func shape(_ raw: JSONValue, shape: ShapeAnnotation) -> [String: JSONValue] {
        let n = AIParameterReport.number
        let window = shape.kind.isCover ? FadeWindow.none : shape.animation.window(span: shape.duration)
        let values: [String: JSONValue] = [
            "start": n(shape.timelineStart), "duration": n(shape.duration), "x": n(shape.centerX), "y": n(shape.centerY),
            "width": n(shape.width), "length": n(shape.width), "height": n(shape.height), "rotation": n(shape.rotationDegrees),
            "line_width": n(shape.lineWidth), "strength": n(shape.coverAmount), "sweep": n(shape.arcSweep),
            "animation_in_duration": n(window.fadeIn), "animation_out_duration": n(window.fadeOut)
        ]
        return report(raw, values: values, limits: ["strength": AIEditLimits.bounds(ShapeKind.coverAmountRange, policy: "clamp"),
                                                   "sweep": AIEditLimits.bounds(ShapeAnnotation.arcSweepRange, policy: "clamp")])
    }

    private static func report(_ raw: JSONValue, values: [String: JSONValue], limits: [String: JSONValue]) -> [String: JSONValue] {
        let reasons = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, "native_overlay_limits, kind_geometry_or_animation_window") })
        var report = AIParameterReport.make(requested: raw, values: values, reasons: reasons)
        var actualLimits = limits.filter { raw[$0.key] != nil }
        for field in ["x", "y"] where raw[field] != nil { actualLimits[field] = AIEditLimits.bounds(0...1, policy: "clamp") }
        report["limits"] = .object(actualLimits)
        return report
    }
}

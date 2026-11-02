import Foundation
import SrtFlowMCPKit

// MARK: - 原生编辑参数的限制与错误（纯值）
//
// 管什么：从生产类型读取范围、统一越界错误（请求 / 合法范围 / 建议），供单项与批量的同一内核调用。
// 不管什么：改时间线、素材探测、撤销；允许的自动限幅仍由生产模型做，AIParameterReport 读最终结果反馈。
enum AIEditLimits {
    static var volume: ClosedRange<Double> { AudioGain.minimumDB...AudioGain.maximumDB }
    static var imageDuration: ClosedRange<Double> { TimelineTrim.clipMinimumDuration...StillImageClipFactory.stillDuration }

    static var json: JSONValue {
        ["speed": bounds(TimelineTrim.clipSpeedRange, policy: "reject"),
         "image_source_duration": bounds(imageDuration, policy: "reject"),
         "source_window_minimum": value(TimelineTrim.clipMinimumDuration),
         "source_boundary_tolerance": value(AIClipEdit.tolerance),
         "volume_db": bounds(volume, policy: "clamp"),
         "crop": bounds(0...ClipCrop.maximumManualInset, policy: "reject"),
         "x": bounds(MCPFramingLimits.center, policy: "reject"),
         "y": bounds(MCPFramingLimits.center, policy: "reject"),
         "scale": bounds(MCPFramingLimits.scale, policy: "reject"),
         "keyframe_scale": bounds(MCPFramingLimits.keyframeScale, policy: "clamp"),
         "rotation": bounds(-360...360, policy: "clamp"),
         "opacity": bounds(0...1, policy: "clamp"),
         "fade_duration": ["minimum": 0, "maximum": "clip timeline duration", "policy": "clamp proportionally; transitions take precedence"]]
    }

    static func require(_ field: String, _ number: Double?, in range: ClosedRange<Double>) throws {
        guard let number else { return }
        guard number.isFinite, range.contains(number) else {
            throw invalid(field, number, minimum: range.lowerBound, maximum: range.upperBound)
        }
    }

    static func nonnegative(_ field: String, _ number: Double?) throws {
        guard let number else { return }
        guard number.isFinite, number >= 0 else { throw invalid(field, number, minimum: 0) }
    }

    static func invalid(_ field: String, _ requested: Double, minimum: Double? = nil, maximum: Double? = nil) -> AIToolError {
        var allowed: [String: JSONValue] = [:]
        if let minimum { allowed["minimum"] = value(minimum) }
        if let maximum { allowed["maximum"] = value(maximum) }
        var suggested = requested.isFinite ? requested : (minimum ?? 0)
        if let minimum { suggested = max(minimum, suggested) }
        if let maximum { suggested = min(maximum, suggested) }
        let range = "\(minimum.map { String($0) } ?? "unbounded") to \(maximum.map { String($0) } ?? "unbounded")"
        var details: [String: JSONValue] = ["status": "invalid_parameter", "parameter": .string(field),
                                          "requested": value(requested), "allowed": .object(allowed), "retryable": false]
        let suggestion: String
        if let minimum, let maximum, minimum > maximum {
            suggestion = "No valid source window remains; use a longer source or an earlier source_in."
            details["suggestion"] = .string(suggestion)
        } else {
            details["suggested"] = value(suggested)
            suggestion = "Use \(suggested)."
            if field.hasPrefix("crop.") { details["suggestion"] = "Use region to select a rectangle beyond manual crop edge limits." }
        }
        return AIToolError("\(field) must be \(range); requested \(requested). \(suggestion) Nothing was applied.", details: details)
    }

    static func bounds(_ range: ClosedRange<Double>, policy: String) -> JSONValue {
        ["minimum": value(range.lowerBound), "maximum": value(range.upperBound), "policy": .string(policy)]
    }

    static func value(_ number: Double) -> JSONValue {
        number.isFinite ? .number(number) : .string(String(describing: number))
    }
}

import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 请求值与最终实际值（纯值）
//
// 管什么：从最终时间线读回数值，与本次请求比较，明确反馈限幅、窗口归一、淡变仲裁和后续联动。
// 不管什么：重新执行限幅 / 修改；没有第二份运算，音量、淡变、取景都问既有生产模型。
enum AIParameterReport {
    static func clip(requested raw: JSONValue, old: EditClip?, clip: EditClip, state: TimelineState, canvas: CGSize) -> [String: JSONValue] {
        let picture = AIFrameFit.describe(clip, canvas: canvas)
        var fades = clip.audioFades
        var transitionIn = 0.0, transitionOut = 0.0
        var expanded = state
        expanded.sortMainClipsByStart()
        expanded = expanded.expandingTransitionHandles()
        if let index = expanded.mainClips.firstIndex(where: { $0.id == clip.id }) {
            transitionIn = index > 0 ? expanded.transitionOverlap(afterMainIndex: index - 1) : 0
            transitionOut = expanded.transitionOverlap(afterMainIndex: index)
            fades = AudioFadeWindow.previewMainTrack(clip: expanded.mainClips[index], transitionBefore: transitionIn, transitionAfter: transitionOut)
        }
        var values: [String: JSONValue] = [
            "start": number(clip.timelineStart), "source_in": number(clip.sourceStart),
            "source_out": number(clip.sourceStart + clip.sourceDuration), "speed": number(clip.speed),
            "volume_db": number(clip.volumeLineDecibels(atTimeline: clip.timelineStart)),
            "fade_in": number(fades.fadeIn), "fade_out": number(fades.fadeOut),
            "x": number(picture.x), "y": number(picture.y), "scale": number(picture.scale),
            "rotation": number(clip.rotationDegrees), "opacity": number(clip.opacity),
            "entrance_duration": number(clip.presetWindow.fadeIn), "exit_duration": number(clip.presetWindow.fadeOut),
            "animation_intensity": number(clip.presetAnimation.intensity)
        ]
        let crop = clip.crop ?? ClipCrop()
        if raw["sound_effect"]?["volume_db"] != nil {
            values["sound_effect"] = ["volume_db": values["volume_db"]!]
        }
        values["crop"] = ["left": number(crop.leading), "right": number(crop.trailing), "top": number(crop.top), "bottom": number(crop.bottom)]
        values["volume_curve"] = .array(clip.volumeCurve.keys.map { ["time": number(clip.timelineTime(atSource: $0.time)), "db": number($0.value)] })
        if let scene = clip.soundScene {
            let names = scene.kind.group == .speaker ? ("distortion", "tone") : ("room_size", "distance")
            values["sound_scene"] = ["kind": .string(scene.kind.rawValue), "intensity": number(scene.amount),
                                     names.0: number(scene.first), names.1: number(scene.second)]
        } else { values["sound_scene"] = "none" }
        var reasons: [String: String] = [
            "source_in": clip.isStillImage ? "image_window_normalized_to_zero" : "source_boundary_tolerance",
            "source_out": clip.isStillImage ? "image_window_normalized_to_zero" : "source_boundary_tolerance",
            "volume_db": "gain_limit_or_existing_volume_curve", "volume_curve": "gain_limits_or_point_tolerance",
            "fade_in": transitionIn > 0 ? "transition_takes_precedence" : "fade_window_clamped_to_clip_duration",
            "fade_out": transitionOut > 0 ? "transition_takes_precedence" : "fade_window_clamped_to_clip_duration",
            "entrance_duration": "picture_fade_window_or_disabled_animation", "exit_duration": "picture_fade_window_or_disabled_animation",
            "rotation": "rotation_limits_or_zero_tolerance", "opacity": "opacity_limits", "animation_intensity": "animation_intensity_limits",
            "x": "native_placement_tolerance_or_final_timeline_settlement", "y": "native_placement_tolerance_or_final_timeline_settlement",
            "scale": "native_placement_tolerance_or_final_timeline_settlement",
            "sound_scene": "sound_scene_limits", "sound_effect": "gain_limits"
        ]
        var curveAdjustment: JSONValue?
        if let old, clip.hasVolumeCurve, old.hasVolumeCurve, raw["volume_db"] != nil, raw["volume_curve"] == nil,
           old.volumeCurve.keys.map(\.time) == clip.volumeCurve.keys.map(\.time) {
            let requestedDB = (try? AIToolArguments(raw).double("volume_db")) ?? 0
            let previous = old.volumeCurve.value(atSourceTime: clip.sourceStart) ?? old.volumeLineDecibels(atTimeline: old.timelineStart)
            let shift = AudioGain.clampedDecibels(requestedDB) - previous
            if old.volumeCurve.keys.contains(where: { !AIEditLimits.volume.contains($0.value + shift) }) {
                reasons["volume_db"] = "gain_limit; shifting the existing curve also clips some keyframe gains"
                curveAdjustment = [
                    "parameter": "volume_curve", "derived_from": "volume_db",
                    "requested": .array(old.volumeCurve.keys.map { ["time": number(clip.timelineTime(atSource: $0.time)), "db": number($0.value + shift)] }),
                    "applied": values["volume_curve"]!, "reason": "shifting_existing_volume_curve_clamps_keyframe_gains"
                ]
            }
        }
        var report = make(requested: raw, values: values, reasons: reasons)
        if let curveAdjustment { report["adjustments"] = .array((report["adjustments"]?.arrayValue ?? []) + [curveAdjustment]) }
        return report
    }

    static func make(requested raw: JSONValue, values: [String: JSONValue], reasons: [String: String] = [:]) -> [String: JSONValue] {
        var requested: [String: JSONValue] = [:]
        var applied: [String: JSONValue] = [:]
        var adjustments: [JSONValue] = []
        for key in values.keys.sorted() {
            guard let rawInput = raw[key], !rawInput.isNull, let actual = values[key] else { continue }
            let input = canonical(rawInput, like: actual)
            requested[key] = input
            applied[key] = actual
            if !matches(input, actual) {
                adjustments.append(["parameter": .string(key), "requested": input, "applied": actual,
                                    "reason": .string(reasons[key] ?? "final_timeline_settlement; see magnet/linkage or later entries in this batch")])
            }
        }
        guard !requested.isEmpty else { return [:] }
        let limits = (AIEditLimits.json.objectValue ?? [:]).filter { requested[$0.key] != nil }
        return ["requested": .object(requested), "applied": .object(applied), "adjustments": .array(adjustments), "limits": .object(limits)]
    }

    static func keyframes(_ raw: JSONValue, clip: EditClip, request: AIKeyframes.Request, canvas: CGSize, frameRate: ProjectFrameRate) -> [String: JSONValue] {
        let animation = clip.clippingAnimation(frameRate: frameRate) ?? ClipAnimation()
        func points(_ track: KeyframeTrack, value: (Keyframe) -> [String: JSONValue]) -> JSONValue {
            .array(track.keys.map { key in
                let timeline = clip.timelineTime(atSource: key.time)
                let time = request.relative ? (timeline - clip.timelineStart) / clip.timelineDuration : timeline
                var point = value(key)
                point["time"] = number(time)
                return .object(point)
            })
        }
        let base = clip.defaultPlacement(canvas: canvas).width
        let values: [String: JSONValue] = [
            "position": points(animation.centerX) { ["x": number($0.value), "y": number(animation.centerY.value(atSourceTime: $0.time) ?? 0.5)] },
            "scale": points(animation.width) { ["value": number(base > 0 ? $0.value / base : 1)] },
            "rotation": points(animation.rotation) { ["degrees": number($0.value)] },
            "opacity": points(animation.opacity) { ["value": number($0.value)] }
        ]
        let reason = "native_keyframe_limits, frame_boundary_holds_or_point_tolerance"
        var report = make(requested: raw, values: values, reasons: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, reason) }))
        var limits = report["limits"]?.objectValue ?? [:]
        if raw["scale"] != nil { limits["scale"] = AIEditLimits.bounds(MCPFramingLimits.keyframeScale, policy: "clamp") }
        if raw["position"] != nil { limits["position"] = AIEditLimits.bounds(MCPFramingLimits.center, policy: "clamp") }
        report["limits"] = .object(limits)
        return report
    }

    static func number(_ value: Double) -> JSONValue { AIEditLimits.value(value) }

    private static func canonical(_ value: JSONValue, like actual: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            if case .number = actual, let number = Double(string), number.isFinite { return .number(number) }
            return value
        case .array(let list):
            let target = actual.arrayValue ?? []
            return .array(list.enumerated().map { index, item in canonical(item, like: target.indices.contains(index) ? target[index] : item) })
        case .object(let object):
            return .object(object.reduce(into: [String: JSONValue]()) { result, entry in
                result[entry.key] = canonical(entry.value, like: actual[entry.key] ?? entry.value)
            })
        default: return value
        }
    }

    private static func matches(_ requested: JSONValue, _ applied: JSONValue) -> Bool {
        switch (requested, applied) {
        case (.number(let a), .number(let b)): return abs(a - b) <= 1e-9 * max(1, abs(a), abs(b))
        case (.object(let a), .object(let b)): return a.allSatisfy { key, value in b[key].map { matches(value, $0) } ?? false }
        case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { matches($0.0, $0.1) }
        default: return requested == applied
        }
    }
}

import Foundation
import SrtFlowMCPKit

// 请求边界 / 原生限幅反馈 / 原子性。只测生产内核；素材在途和真实工程提交由 ParameterLimits App 夹具验证。
func runParameterLimitChecks() {
    parameterRangeChecks()
    parameterWindowChecks()
    parameterFeedbackChecks()
    parameterAtomicChecks()
    parameterOverlayChecks()
}

private func parameterRangeChecks() {
    checkEqual(AIEditLimits.json["volume_db"]?["maximum"]?.doubleValue, AudioGain.maximumDB, "limits use native gain maximum without rounding")
    checkEqual(AIEditLimits.json["speed"]?["minimum"]?.doubleValue, TimelineTrim.clipSpeedRange.lowerBound, "speed uses native trim limit")
    checkEqual(AIEditLimits.json["image_source_duration"]?["maximum"]?.doubleValue, StillImageClipFactory.stillDuration, "images use actual loop length")
    checkEqual(AIEditLimits.json["crop"]?["maximum"]?.doubleValue, ClipCrop.maximumManualInset, "crop uses native legacy inset")
    for speed in [TimelineTrim.clipSpeedRange.lowerBound, 1, TimelineTrim.clipSpeedRange.upperBound] {
        do { try AIClipParameters.validate(AIClipChange(speed: speed)) }
        catch { check(false, "valid speed \(speed): \(error)") }
    }
    for speed in [TimelineTrim.clipSpeedRange.lowerBound - 0.001, TimelineTrim.clipSpeedRange.upperBound + 0.001] {
        limitError("speed outside range", field: "speed", requested: speed) { try AIClipParameters.validate(AIClipChange(speed: speed)) }
    }
    limitError("negative start", field: "start", requested: -1) { try AIClipParameters.validate(AIClipChange(start: -1)) }
    let ranges: [(String, ClosedRange<Double>)] = [("x", MCPFramingLimits.center), ("y", MCPFramingLimits.center), ("scale", MCPFramingLimits.scale)]
    for (field, range) in ranges {
        for number in [range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound] {
            do { _ = try AIFramingRequest(args([field: .number(number)])) }
            catch { check(false, "\(field) boundary \(number) should be accepted") }
        }
        for number in [range.lowerBound - 0.001, range.upperBound + 0.001] {
            limitError("\(field) cannot silently clamp", field: field, requested: number) { _ = try AIFramingRequest(args([field: .number(number)])) }
        }
    }
    for edge in ["left", "right", "top", "bottom"] {
        for number in [0.0, 0.1, ClipCrop.maximumManualInset] {
            do { _ = try AIFramingRequest(args(["crop": .object([edge: .number(number)])])) }
            catch { check(false, "valid crop \(edge) \(number)") }
        }
        for number in [-0.01, ClipCrop.maximumManualInset + 0.01] {
            limitError("crop cannot silently clamp", field: "crop.\(edge)", requested: number) {
                _ = try AIFramingRequest(args(["crop": .object([edge: .number(number)])]))
            }
        }
    }
    check(MCPToolName.getTimeline.definition.description.contains("edit_limits"), "AI can discover runtime ranges")
    for (field, bound) in [("speed", "maximum"), ("crop", "maximum"), ("volume_db", "maximum")] {
        let schema = MCPToolName.editClip.definition.inputSchema["properties"]?[field]
        check(schema?[bound] == nil, "\(field) schema does not duplicate native bounds")
    }
}

private func parameterWindowChecks() {
    func window(_ start: Double?, _ end: Double?, image: Bool = false, asset: Double = 10) throws -> AIClipSourceWindow {
        try AIClipSourceWindow.resolve(sourceIn: start, sourceOut: end, oldIn: 0, oldOut: 5,
                                      assetDuration: asset, isImage: image, stillDuration: StillImageClipFactory.stillDuration)
    }
    for duration in [TimelineTrim.clipMinimumDuration, 5, StillImageClipFactory.stillDuration] {
        do { checkEqual(try window(0, duration, image: true).duration, duration, "image boundary retained exactly") }
        catch { check(false, "valid image duration: \(error)") }
    }
    for duration in [TimelineTrim.clipMinimumDuration / 2, StillImageClipFactory.stillDuration + 1] {
        limitError("image duration rejects truncation", field: "source_out", requested: duration) { _ = try window(0, duration, image: true) }
    }
    do {
        let normalized = try window(2, 7, image: true)
        checkEqual(normalized.start, 0, "image source time intentionally normalized")
        checkEqual(normalized.duration, 5, "image window length retained")
        checkEqual(try window(-0.01, 10.01).duration, 10, "existing source rounding tolerance retained")
        checkEqual(try window(9.9, 10).duration, TimelineTrim.clipMinimumDuration, "minimum tail window accepted")
    } catch { check(false, "valid source windows: \(error)") }
    for (start, end, field, requested) in [(-0.1, 5.0, "source_in", -0.1), (9.95, 10, "source_in", 9.95), (2, 11, "source_out", 11.0), (2, 2.01, "source_out", 2.01)] {
        limitError("source window rejected before editing", field: field, requested: requested) { _ = try window(start, end) }
    }
    do {
        _ = try window(20, nil)
        check(false, "invalid source_in must fail")
    } catch let error as AIToolError {
        let suggested = error.details["suggested"]?.doubleValue
        check(suggested != nil && (try? window(suggested, nil)) != nil, "suggested source_in also fits the unchanged source_out")
    } catch { check(false, "unexpected source_in error") }
    do {
        _ = try window(0, 0.02, asset: 0.03)
        check(false, "source shorter than minimum cannot offer impossible window")
    } catch let error as AIToolError {
        check(error.details["suggested"] == nil && error.details["suggestion"] != nil, "empty valid interval offers a different source, not an invalid number")
    } catch { check(false, "unexpected short source error") }
}

private let parameterCanvas = CGSize(width: 1920, height: 1080)

private func parameterFeedbackChecks() {
    do {
        var state = TimelineState()
        let clip = videoClip(0, 4, asset: 10)
        state.mainClips = [clip]
        for db in [AudioGain.minimumDB - 1, AudioGain.minimumDB, -8, AudioGain.maximumDB, 8.1] {
            let next = try AIClipEdit.apply(AIClipChange(volumeDB: db), to: clip.id, linkage: false, stillDuration: StillImageClipFactory.stillDuration, in: state)
            let updated = next.clip(with: clip.id)!
            let report = AIParameterReport.clip(requested: ["volume_db": .number(db)], old: clip, clip: updated, state: next, canvas: parameterCanvas)
            checkEqual(report["requested"]?["volume_db"]?.doubleValue, db, "volume request retained")
            checkEqual(report["applied"]?["volume_db"]?.doubleValue, updated.volumeLineDecibels(atTimeline: 0), "volume feedback reads actual model, no one-decimal rounding")
            let expectedAdjustment = !AIEditLimits.volume.contains(db)
            checkEqual(report["adjustments"]?.arrayValue?.isEmpty, !expectedAdjustment, "only changed gain values have an adjustment")
            if expectedAdjustment { check(report["adjustments"]?.arrayValue?.first?["reason"]?.stringValue?.isEmpty == false, "gain clamp explains why") }
        }
        let fadeChange = AIClipChange(fadeIn: 5, fadeOut: 5)
        let next = try AIClipEdit.apply(fadeChange, to: clip.id, linkage: false, stillDuration: 60, in: state)
        let report = AIParameterReport.clip(requested: ["fade_in": 5, "fade_out": 5], old: clip, clip: next.clip(with: clip.id)!, state: next, canvas: parameterCanvas)
        checkEqual(report["applied"]?["fade_in"]?.doubleValue, 2, "effective proportional fade window is reported")
        checkEqual(report["applied"]?["fade_out"]?.doubleValue, 2, "both fade edges report effective values")
        var curvedState = state
        var curveChange = AIClipChange()
        curveChange.details = try AIClipDetails(args(["volume_curve": [["time": 0, "db": -3], ["time": 4, "db": 5]]]))
        curvedState = try AIClipEdit.apply(curveChange, to: clip.id, linkage: false, stillDuration: 60, in: curvedState)
        let curved = curvedState.clip(with: clip.id)!
        let shifted = try AIClipEdit.apply(AIClipChange(volumeDB: AudioGain.maximumDB), to: clip.id, linkage: false, stillDuration: 60, in: curvedState)
        let curvedReport = AIParameterReport.clip(requested: ["volume_db": .number(AudioGain.maximumDB)], old: curved,
                                                clip: shifted.clip(with: clip.id)!, state: shifted, canvas: parameterCanvas)
        checkEqual(curvedReport["applied"]?["volume_db"]?.doubleValue, AudioGain.maximumDB, "volume curve feedback is actual start gain, not unused static volume")
        checkEqual(shifted.clip(with: clip.id)?.volumeCurve.keys.last?.value, AudioGain.maximumDB, "native curve shift saturates later points")
        check(curvedReport["adjustments"]?.arrayValue?.contains { $0["parameter"] == "volume_curve" && $0["derived_from"] == "volume_db" } == true, "curve point saturation is explicit even when requested start gain is fully applied")
        let trimAndGain = try AIClipEdit.apply(AIClipChange(sourceIn: 2, volumeDB: 2), to: clip.id, linkage: false, stillDuration: 60, in: curvedState)
        let trimReport = AIParameterReport.clip(requested: ["source_in": 2, "volume_db": 2], old: curved,
                                              clip: trimAndGain.clip(with: clip.id)!, state: trimAndGain, canvas: parameterCanvas)
        check(trimReport["adjustments"]?.arrayValue?.contains { $0["parameter"] == "volume_curve" } != true,
              "curve shift after trimming starts at the new source position; no false saturation warning")
        let raw: JSONValue = ["relative": true, "scale": [["time": 0, "value": 0.001], ["time": 0.75, "value": 1.123456789], ["time": 1, "value": 10]], "opacity": [["time": 0, "value": -1]]]
        let request = try AIKeyframes.parse(AIToolArguments(raw))
        var animated = clip
        try AIKeyframes.apply(request, to: &animated, canvas: parameterCanvas, frameRate: .fps30)
        let keys = AIParameterReport.keyframes(raw, clip: animated, request: request, canvas: parameterCanvas, frameRate: .fps30)
        let applied = keys["applied"]?["scale"]?.arrayValue
        checkEqual(applied?.first?["value"]?.doubleValue, MCPFramingLimits.keyframeScale.lowerBound, "keyframe minimum clamp is visible")
        checkEqual(applied?.last?["value"]?.doubleValue, MCPFramingLimits.keyframeScale.upperBound, "keyframe maximum clamp is visible")
        check(abs((applied?[1]["value"]?.doubleValue ?? 0) - 1.123456789) < 1e-12, "feedback does not round a valid keyframe value")
        checkEqual(keys["applied"]?["opacity"]?.arrayValue?.first?["value"]?.doubleValue, 0, "keyframe opacity clamp is visible")
        let same = AIParameterReport.make(requested: ["number": ["prefix": "100"]], values: ["number": ["prefix": "100"]])
        checkEqual(same["requested"]?["number"]?["prefix"], "100", "numeric-looking text is still text")
        checkEqual(same["adjustments"]?.arrayValue?.count, 0, "string prefixes do not cause false numeric adjustments")
    } catch { check(false, "parameter feedback: \(error)") }
}

private func parameterAtomicChecks() {
    var state = TimelineState()
    let clip = videoClip(0, 4, asset: 10)
    state.mainClips = [clip]
    var batch = AIClipBatch(state)
    do {
        try batch.append(AIClipEditPlan(id: clip.id, change: AIClipChange(start: 2), canvas: parameterCanvas), linkage: false, stillDuration: 60, canvas: parameterCanvas)
        try batch.append(AIClipEditPlan(id: clip.id, change: AIClipChange(sourceOut: 11, speed: 2, volumeDB: 8.1), canvas: parameterCanvas), linkage: false, stillDuration: 60, canvas: parameterCanvas)
        check(false, "bad last source window must reject batch")
    } catch { checkEqual(state.mainClips, [clip], "multi-parameter error does not change original timeline") }
    var animated = clip
    checkThrows("later bad keyframe time cannot leave earlier tracks applied") {
        try AIKeyframes.apply(AIKeyframes.Request(scale: [(0, 2)], opacity: [(20, 0)]), to: &animated, canvas: parameterCanvas, frameRate: .fps30)
    }
    checkEqual(animated, clip, "keyframes validate and apply only to local animation until all valid")
    let error = AIBatchItems.failure(AIEditLimits.invalid("speed", 9, minimum: 0.1, maximum: 8), key: "clips", index: 1)
    checkEqual(error.details["index"], 1, "batch preserves failing item index")
    checkEqual(error.details["allowed"]?["maximum"], 8, "batch preserves legal range")
    do {
        let text = error.result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        checkEqual(payload["changed"], false, "router error explicitly says no modification")
        checkEqual(payload["status"], "invalid_parameter", "structured status survives MCP text wrapper")
        checkEqual(error.result["isError"], true, "invalid parameter is a protocol tool error")
    } catch { check(false, "structured error serialization: \(error)") }
    checkEqual(AIToolError("legacy").result["content"]?.arrayValue?.first?["text"], "legacy", "legacy errors keep their existing text contract")
}

private func parameterOverlayChecks() {
    do {
        var state = TimelineState()
        let raw: JSONValue = ["text": "test", "font_size": 2000, "box_width": 2, "x": -1, "duration": 0.01, "number": ["from": 0, "to": 10, "prefix": "100"]]
        _ = try AIOverlayEdits.text(AIToolArguments(raw), at: 0, in: &state)
        let text = state.textOverlays[0]
        let report = AIOverlayParameterReport.text(raw, overlay: text)
        checkEqual(report["applied"]?["font_size"]?.doubleValue, text.style.fontSize, "text reports native font limit")
        checkEqual(report["applied"]?["box_width"]?.doubleValue, text.boxWidth, "text reports native wrap limit")
        checkEqual(report["applied"]?["duration"]?.doubleValue, text.duration, "text reports native duration minimum")
        check((report["adjustments"]?.arrayValue?.count ?? 0) >= 4, "text clamps are explicit")
        let shapeRaw: JSONValue = ["kind": "line", "length": 2, "x": -1, "rotation": 120]
        let id = try AIOverlayEdits.shape(AIToolArguments(shapeRaw), at: 0, in: &state)
        let shape = state.shapes.first { $0.id == id }!
        let shapeReport = AIOverlayParameterReport.shape(shapeRaw, shape: shape)
        checkEqual(shapeReport["applied"]?["rotation"]?.doubleValue, 90, "line-specific rotation limit reported")
        checkEqual(shapeReport["applied"]?["length"]?.doubleValue, shape.width, "length alias reports actual native width")
    } catch { check(false, "overlay parameter feedback: \(error)") }
}

private func limitError(_ message: String, field: String, requested: Double, _ body: () throws -> Void) {
    do { try body(); check(false, message + ": must fail before modification") }
    catch let error as AIToolError {
        checkEqual(error.details["status"], "invalid_parameter", message + ": typed error")
        checkEqual(error.details["parameter"]?.stringValue, field, message + ": parameter")
        checkEqual(error.details["requested"]?.doubleValue, requested, message + ": requested value")
        let allowed = error.details["allowed"]
        let suggestion = error.details["suggested"]?.doubleValue
        check(suggestion != nil && suggestion!.isFinite && suggestion! >= (allowed?["minimum"]?.doubleValue ?? -Double.greatestFiniteMagnitude)
              && suggestion! <= (allowed?["maximum"]?.doubleValue ?? Double.greatestFiniteMagnitude), message + ": actionable suggestion within legal range")
    } catch { check(false, message + ": unexpected error \(error)") }
}

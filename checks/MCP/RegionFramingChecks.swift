import CoreGraphics
import Foundation
import SrtFlowMCPKit

// region 的参数、原生几何、旧入口兼容与存取往返；真实 look / 预览 / 导出像素另由 check-region-framing 跑。
func runRegionFramingChecks() {
    let valid: JSONValue = ["x": 0.91, "y": 0.92, "width": 0.09, "height": 0.08]
    checkEqual((try? AIFramingRequest(args(["region": valid])))?.fit, .fit, "region defaults to complete fit")
    checkEqual((try? AIFramingRequest(args(["region": valid, "fit": "fill"])))?.region,
               CGRect(x: 0.91, y: 0.92, width: 0.09, height: 0.08), "region keeps source top-left fractions")
    for bad: JSONValue in [1, [], [:], ["x": 0, "y": 0, "width": 0.1],
                           ["x": -0.01, "y": 0, "width": 0.1, "height": 0.1],
                           ["x": 0, "y": 0, "width": -0.1, "height": 0.1],
                           ["x": 0, "y": 0, "width": 0, "height": 0.1],
                           ["x": 0.95, "y": 0, "width": 0.1, "height": 0.1],
                           ["x": 0, "y": 1, "width": 0.1, "height": 0.1]] {
        checkThrows("region rejects malformed / outside rectangle: \(bad)") { _ = try AIFramingRequest(args(["region": bad])) }
    }
    for (key, value): (String, JSONValue) in [
        ("crop", [:]), ("remove_black_bars", false), ("focus", "center"), ("focus_x", 0.5), ("focus_y", 0.5),
        ("follow", false), ("x", 0.5), ("y", 0.5), ("scale", 2), ("rotation", 0),
        ("flip_horizontal", false), ("flip_vertical", false)
    ] {
        checkThrows("region refuses ambiguous \(key)") {
            _ = try AIFramingRequest(args(["region": valid, "fit": "fill", key: value]))
        }
    }
    let schema = MCPToolName.editClip.definition.inputSchema["properties"]?["region"]
    checkEqual(Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []), Set(["x", "y", "width", "height"]), "region schema names all four required fields")
    check(MCPToolName.editClip.definition.description.prefix(512).contains("region={x,y,width,height}"), "region survives client description truncation")
    for tool: MCPToolName in [.editClip, .editClips] {
        let item: JSONValue = ["clip_id": "1234", "region": valid]
        let input: JSONValue = tool == .editClip ? item : ["clips": [item]]
        checkEqual(MCPArgumentCheck.problem(tool: tool, arguments: input), nil, "\(tool) accepts shared region schema")
        let typo: JSONValue = ["clip_id": "1234", "region": ["x": 0, "y": 0, "width": 1, "height": 1, "left": 0]]
        check(MCPArgumentCheck.problem(tool: tool, arguments: tool == .editClip ? typo : ["clips": [typo]]) != nil,
              "\(tool) refuses unknown nested region names")
    }

    var cases = 0
    var errors = 0
    for display in [CGSize(width: 1920, height: 1080), .init(width: 1080, height: 1920), .init(width: 1080, height: 1080)] {
        for canvas in [CGSize(width: 1920, height: 1080), .init(width: 1080, height: 1920), .init(width: 1080, height: 1080)] {
            let info = MediaInfo(duration: 2, displaySize: display, frameRate: 24, videoCodec: "h264", audioCodec: nil,
                                 hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
            let clip = EditClip(sourceURL: URL(fileURLWithPath: "/m/region.mp4"), sourceDuration: 2, timelineStart: 0, info: info)
            for origin in [CGPoint(x: 0, y: 0), .init(x: 0.96, y: 0), .init(x: 0, y: 0.94), .init(x: 0.96, y: 0.94), .init(x: 0.48, y: 0.47)] {
                let region = CGRect(origin: origin, size: .init(width: 0.04, height: 0.06))
                for fill in [false, true] {
                    cases += 1
                    do {
                        let framing = try AIRegionFraming.make(clip, canvas: canvas, region: region, fill: fill)
                        var result = clip
                        result.crop = framing.crop
                        result.placement = framing.placement
                        let kept = AIFrameFit.region(of: result.crop)
                        let target = result.resolvedPlacement(canvas: canvas).frame(in: canvas)
                        // 独立算源窗到画布的仿射，不能只拿被测函数的 summary 跟自己比。
                        let sx = target.width / (kept.width * display.width)
                        let sy = target.height / (kept.height * display.height)
                        if abs(sx - sy) > 1e-7 { errors += 1 }
                        if fill {
                            if target.minX > 0.5 || target.minY > 0.5 || target.maxX < canvas.width - 0.5 || target.maxY < canvas.height - 0.5 { errors += 1 }
                        } else {
                            if !kept.insetBy(dx: -1e-9, dy: -1e-9).contains(region) { errors += 1 }
                            if target.minX < -0.5 || target.minY < -0.5 || target.maxX > canvas.width + 0.5 || target.maxY > canvas.height + 0.5 { errors += 1 }
                        }
                        let back = try JSONDecoder().decode(EditClip.self, from: JSONEncoder().encode(result))
                        if back.crop != result.crop || back.placement != result.placement { errors += 1 }
                    } catch { errors += 1 }
                }
            }
        }
    }
    checkEqual(cases, 90, "region geometry covers source/canvas aspects, four corners and <10% selections")
    checkEqual(errors, 0, "region geometry is unstretched, stays within bounds and survives Codable")
    let exact = ClipCrop(keeping: CGRect(x: 0.91, y: 0.92, width: 0.09, height: 0.08))!
    check(exact.exceedsLegacyLimits, "small corner selection is native crop beyond legacy edge limits")
    checkEqual(exact.setting(\.bottom, to: 0.01).leading, exact.leading, "inspector edit preserves other extended crop edges")
    check(exact.setting(\.trailing, to: 1).trailing + exact.leading < 1, "inspector cannot collapse opposite edges")
    checkEqual(ClipCrop(leading: 0.91).leading, 0.45, "existing crop initializer still clamps at 45%")
    let eightK = MediaInfo(duration: 2, displaySize: .init(width: 7680, height: 4320), frameRate: 24, videoCodec: "h264", audioCodec: nil,
                           hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
    let large = EditClip(sourceURL: URL(fileURLWithPath: "/m/8k.mp4"), sourceDuration: 2, timelineStart: 0, info: eightK)
    let almostWhole = try? AIRegionFraming.make(large, canvas: .init(width: 1920, height: 1080),
                                              region: CGRect(x: 1.0 / 7680, y: 0, width: 1 - 1.0 / 7680, height: 1), fill: false)
    check(almostWhole?.crop?.isEmpty == false && abs((almostWhole?.crop?.leading ?? 0) * 7680 - 1) < 1e-8,
          "region preserves a single source pixel inset even below the legacy empty threshold")
    var onePixel = large
    onePixel.crop = almostWhole?.crop
    let onePixelReport = AITimelineSummary.picture(onePixel, canvas: .init(width: 1920, height: 1080), always: true)
    check((onePixelReport?["crop"]?["left"]?.doubleValue ?? 0) > 0 && (onePixelReport?["region"]?["x"]?.doubleValue ?? 0) > 0,
          "region feedback never rounds a source pixel inset down to zero")
    let info = MediaInfo(duration: 2, displaySize: .init(width: 1920, height: 1080), frameRate: 24, videoCodec: "h264", audioCodec: nil,
                         hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/m/region.mp4"), sourceDuration: 2, timelineStart: 0, info: info)
    let canvas = CGSize(width: 1920, height: 1080)
    let selected = CGRect(x: 0.7, y: 0.8, width: 0.1, height: 0.1)
    checkThrows("region rejects a subpixel rectangle") {
        _ = try AIRegionFraming.make(clip, canvas: canvas, region: CGRect(x: 0, y: 0, width: 0.0001, height: 0.1), fill: false)
    }
    checkThrows("region rejects a fill window smaller than two pixels") {
        _ = try AIRegionFraming.make(clip, canvas: canvas, region: CGRect(x: 0, y: 0, width: 2.0 / 1920, height: 0.5), fill: true)
    }
    clip.rotationDegrees = 10
    checkThrows("region refuses existing extra rotation rather than silently clipping fit") {
        _ = try AIRegionFraming.make(clip, canvas: canvas, region: selected, fill: false)
    }
    clip.rotationDegrees = 0
    var animation = ClipAnimation()
    animation.rotation.set(10, atSourceTime: 0, tolerance: 0.001)
    clip.animation = animation
    checkThrows("region refuses rotation keyframes unless explicitly cleared") {
        _ = try AIRegionFraming.make(clip, canvas: canvas, region: selected, fill: true)
    }
    check((try? AIRegionFraming.make(clip, canvas: canvas, region: selected, fill: true, clearsKeyframes: true)) != nil,
          "region permits explicit keyframes=clear")
    clip.animation = nil
    clip.flippedHorizontally = true
    let mirrored = try? AIRegionFraming.make(clip, canvas: canvas, region: selected, fill: false)
    check(mirrored != nil, "existing flip preserves source selection semantics")
    clip.presetAnimation.entrance = .zoom
    checkThrows("region refuses a motion preset") { _ = try AIRegionFraming.make(clip, canvas: canvas, region: selected, fill: true) }
}

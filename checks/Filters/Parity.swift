import CoreImage
import Foundation
import SrtFlowCore

// 三、预览 vs 导出，逐像素比对（从 main.swift 拆出来，2026-10-14）：配方算出来的值 ↔ CoreImage 渲出来的值 ↔ 真跑 ffmpeg
// 出片后解出来的值。辅助函数（check、run、lookup、root）在 main.swift。

// MARK: - 三、预览 vs 导出，逐像素

/// 预览那条路：同一份表交给 CIColorCubeWithColorSpace，渲一个 1×1 出来。
///
/// 位图和渲染都钉在 `FilterLUT.workingColorSpace` 上 —— 定义域必须和 ffmpeg
/// 那边（解码出来的 709 编码值直接进 lut3d）是同一个，否则比的是两件事。
func previewPixel(
    _ input: (UInt8, UInt8, UInt8), preset: FilterPreset, strength: Double
) -> (Double, Double, Double)? {
    let space = FilterLUT.workingColorSpace
    guard let filter = FilterLUT.previewFilter(for: preset, strength: strength, name: "check")
    else { return nil }
    let source = Data([input.0, input.1, input.2, 255])
    let image = CIImage(
        bitmapData: source, bytesPerRow: 4, size: CGSize(width: 1, height: 1),
        format: .RGBA8, colorSpace: space
    )
    filter.setValue(image, forKey: kCIInputImageKey)
    guard let output = filter.outputImage else { return nil }
    let context = CIContext(options: [
        .workingColorSpace: space, .outputColorSpace: space,
    ])
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
        output, toBitmap: &pixel, rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8, colorSpace: space
    )
    return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
}

/// 从一个视频文件的指定时刻取一个像素（取画面正中，避开边缘）。
func exportedPixel(_ url: URL, at seconds: Double) -> (Double, Double, Double)? {
    let raw = root.appendingPathComponent("pixel-\(UUID().uuidString).raw")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-ss", String(seconds), "-frames:v", "1",
        "-vf", "crop=8:8:(iw-8)/2:(ih-8)/2,scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path,
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), data.count >= 3 else {
        print("取像素失败：\(out)")
        return nil
    }
    return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
}

/// 真跑一遍生产导出：`VideoEditExportGraph.plan()` → ffmpeg → 成片。返回成片和拼成一行的参数；失败时记一条红、返回 nil。
func exportTimeline(_ state: TimelineState, name: String) async -> (url: URL, arguments: String)? {
    let output = root.appendingPathComponent("\(name).mp4")
    let plan: VideoEditExportGraph.Plan
    do {
        plan = try await VideoEditExportGraph.plan(
            state: state,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: output, watermark: nil
        )
    } catch {
        check(false, "plan() 失败（\(name)）：\(error)")
        return nil
    }
    defer { try? FileManager.default.removeItem(at: plan.workspace) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = plan.arguments
    process.currentDirectoryURL = plan.workspace
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let log = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        check(false, "ffmpeg 跑失败（\(name)）：\(String(data: log, encoding: .utf8) ?? "")")
        return nil
    }
    try? FileManager.default.moveItem(at: plan.tempOutput, to: output)
    return (output, plan.arguments.joined(separator: " "))
}

func parity() async {
    // 纯色素材：颜色是平的，编码损失可以忽略，取到的像素就是管线算出来的值。
    // 刻意选一个**远离夹取区**的中间色（见 FilterLUT.apply：白/黑附近会被
    // clamp，那里的表不再局部线性，三方就对不齐了 —— 那是数学，不是 bug）。
    let input: (UInt8, UInt8, UInt8) = (180, 90, 60)
    let source = root.appendingPathComponent("flat.mp4")
    let hex = String(format: "0x%02X%02X%02X", input.0, input.1, input.2)
    let (makeCode, makeOut) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "color=c=\(hex):size=320x180:rate=30:duration=3",
        "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", source.path,
    ])
    guard makeCode == 0 else { print("造纯色素材失败：\(makeOut)"); finish(1) }

    // 素材本身解出来是什么颜色（yuv 往返会差一两个码值）—— 比对要以它为准，
    // 拿名义色当基准的话，差的是编码误差，不是管线误差。
    guard let decoded = exportedPixel(source, at: 1.0) else {
        check(false, "素材像素取不到"); return
    }
    let decoded8 = (
        UInt8((decoded.0 * 255).rounded()),
        UInt8((decoded.1 * 255).rounded()),
        UInt8((decoded.2 * 255).rounded())
    )

    // 预览那条路单独对十款都过一遍（不用跑 ffmpeg，很便宜）：一款配方写错
    // 只会让那一款不对，靠一款代表验不出来。
    for preset in FilterPreset.allCases {
        let expected = lookup(FilterLUT.fullTable(for: preset), (
            Double(decoded8.0) / 255, Double(decoded8.1) / 255, Double(decoded8.2) / 255
        ))
        guard let rendered = previewPixel(decoded8, preset: preset, strength: 1) else {
            check(false, "\(preset.rawValue)：CoreImage 渲不出来"); continue
        }
        checkClose(rendered.0, expected.0, 1.5 / 255, "\(preset.rawValue) 预览 R 对得上查表结果")
        checkClose(rendered.1, expected.1, 1.5 / 255, "\(preset.rawValue) 预览 G 对得上查表结果")
        checkClose(rendered.2, expected.2, 1.5 / 255, "\(preset.rawValue) 预览 B 对得上查表结果")
    }

    let info = MediaInfo(
        duration: 3, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )

    // 真跑 ffmpeg 的三组。`inkShadow` 特意选进来：它带 gamma（非线性）且饱和
    // 归零，和线性的 `coldIron` 是两种形状，能把「表逼近配方」那一段也走到。
    for (preset, strength) in [
        (FilterPreset.coldIron, 1.0), (FilterPreset.coldIron, 0.6), (FilterPreset.inkShadow, 1.0),
    ] {
        var state = TimelineState()
        state.frameRate = .fallback
        state.canvasRatio = .wide16x9
        state.mainClips = [
            EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info)
        ]
        // 只盖住 1.0…2.5s：区间外必须是原色，这是 `enable` 那一项的回归。
        state.filters = [
            FilterClip(
                preset: preset, strength: strength,
                timelineStart: 1.0, duration: 1.5, layer: 0
            )
        ]

        guard let rendered = await exportTimeline(state, name: "graded-\(preset.rawValue)-\(strength)")
        else { continue }
        let output = rendered.url
        let joined = rendered.arguments
        check(joined.contains("lut3d=file=filter0.cube"), "滤镜链真的用上了 lut3d（\(preset.rawValue) 强度 \(strength)）")
        check(joined.contains("interp=trilinear"), "必须显式写 interp=trilinear（默认是 tetrahedral）")
        check(joined.contains("format=gbrp"), "lut3d 之前要把像素格式钉成 RGB")
        check(joined.contains("enable='between(t,1,2.5)'"), "enable 区间就是滤镜段的起止")

        // ① 「应该是多少」= 拿**这一份表**三线性查一次。
        //
        // 注意不能拿 `FilterLUT.apply(recipe, …)` 当期望值：带 gamma 的配方是
        // 非线性的，33³ 的表只是它的逼近，两条管线实现的都是**查表**而不是配方
        // 本身。表和配方的关系由上面那条「格点对得上」守（lutMath）。
        let normalized = (
            Double(decoded8.0) / 255, Double(decoded8.1) / 255, Double(decoded8.2) / 255
        )
        let expected = lookup(FilterLUT.table(for: preset, strength: strength), normalized)

        // ② 预览那条路。
        guard let preview = previewPixel(decoded8, preset: preset, strength: strength) else {
            check(false, "CoreImage 渲不出来"); continue
        }
        // CoreImage 只有 8bit 量化误差，容差给 1.5/255。
        checkClose(preview.0, expected.0, 1.5 / 255, "预览 R 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")
        checkClose(preview.1, expected.1, 1.5 / 255, "预览 G 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")
        checkClose(preview.2, expected.2, 1.5 / 255, "预览 B 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")

        // ③ 导出那条路。多一趟 yuv 往返 + 一次有损编码，容差给 4/255。
        guard let exported = exportedPixel(output, at: 1.6) else {
            check(false, "成片像素取不到"); continue
        }
        checkClose(exported.0, expected.0, 4 / 255, "成片 R 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")
        checkClose(exported.1, expected.1, 4 / 255, "成片 G 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")
        checkClose(exported.2, expected.2, 4 / 255, "成片 B 对得上查表结果（\(preset.rawValue) 强度 \(strength)）")

        // ④ 预览和导出互相对得上（这一刀的验收项本身）。
        checkClose(exported.0, preview.0, 4 / 255, "预览 R == 成片 R（\(preset.rawValue) 强度 \(strength)）")
        checkClose(exported.1, preview.1, 4 / 255, "预览 G == 成片 G（\(preset.rawValue) 强度 \(strength)）")
        checkClose(exported.2, preview.2, 4 / 255, "预览 B == 成片 B（\(preset.rawValue) 强度 \(strength)）")

        // ⑤ `enable` 区间之外必须是原片。
        guard let before = exportedPixel(output, at: 0.4) else {
            check(false, "区间外像素取不到"); continue
        }
        checkClose(before.0, normalized.0, 4 / 255, "滤镜段之前是原色 R（\(preset.rawValue) 强度 \(strength)）")
        checkClose(before.1, normalized.1, 4 / 255, "滤镜段之前是原色 G（\(preset.rawValue) 强度 \(strength)）")
        checkClose(before.2, normalized.2, 4 / 255, "滤镜段之前是原色 B（\(preset.rawValue) 强度 \(strength)）")
    }

    // 强度 0 整条跳过：成片应当和原片一样，滤镜图里连 lut3d 都不该有。
    var zero = TimelineState()
    zero.frameRate = .fallback
    zero.canvasRatio = .wide16x9
    zero.mainClips = [
        EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info)
    ]
    zero.filters = [
        FilterClip(preset: .coldIron, strength: 0, timelineStart: 0, duration: 3, layer: 0)
    ]
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: zero,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: root.appendingPathComponent("zero.mp4"), watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        check(
            !plan.arguments.joined(separator: " ").contains("lut3d"),
            "强度 0 的滤镜段不进滤镜图（原片应当逐像素不变）"
        )
    } catch {
        check(false, "强度 0 的 plan() 失败：\(error)")
    }
}

import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore
import VideoToolbox

// **带透明的视频**（2026-11-16，docs/bugfixes/2026-11-16-alpha-video-premultiplied-or-straight.md）：放在上层轨（或 V1）的
// 带透明的视频，预览和成片都要按文件里的标记叠 —— 以前预览一律当预乘、导出一律当直通，同一个文件两边不可能都对
// （存预乘的成片半透明处发暗，存直通的预览里光成了一条白带）。
//
// 素材用 AVAssetWriter 现做（不用被测的 ffmpeg 造）：320×180、2 秒，四条竖带 —— 全透明 / 50% 的绿 / 不透明的蓝 / 25% 的白（光），
// 存成 ProRes 4444（预乘、直通、存预乘却不写标记）和 HEVC 带透明（预乘、直通；这台机器做不出来就明说跳过，不算过）。
// 压在红色主轨上（或单独在 V1），预览（和预览同一个 builder）、成片（生产 plan() + ffmpeg）各取四条带的中心，和「正确参考」比：
// 参考 = 这条管线自己的解码器解出来的预乘色 × 不透明度 + 同一条管线里只放底片时量到的底色 ×（1 − alpha × 不透明度）；全透明那条带
// 就得等于底色（透明处露出下面那一层 —— 带关键帧的段 matte 用了纯白的话它是黑的）。每条管线拿自己量到的底色、自己的解码器算，
// 色彩空间和编码的那点差不进账；预乘 / 直通弄反的话 50% 的绿差约 50 级、
// 25% 的白差 48–190 级，容差 10 级分得开。组合：不透明度、渐变、奇数边裁切 + 缩小、关键帧（fill + matte）、入场动画、
// 单独在 V1、V1 + 不透明度、没记标记的老段、1080p 以上的画布、硬件编码、优化媒体的块不许换进来。
// 素材和探针（现做文件、各管线的解码参考、取码值）在 AlphaVideoProbes.swift。

let alphaSize = CGSize(width: 320, height: 180)
/// 四条竖带存的直通色和 alpha（0…255）。
let bandColors: [[Double]] = [[0, 0, 0, 0], [40, 200, 80, 128], [30, 60, 220, 255], [255, 255, 255, 64]]
/// 四条带的中心（素材 / 1× 画布上的像素）。
let bandCenters: [CGPoint] = [CGPoint(x: 40, y: 90), CGPoint(x: 120, y: 90), CGPoint(x: 200, y: 90), CGPoint(x: 280, y: 90)]
/// 对的叠法和参考差不过这么多级（0…255，实测最多 4）；弄反了至少差 26 级（渐变走到一半、不透明度 0.6 时差得最少）。
private let alphaTolerance = 10.0
/// 素材一律标明 SMPTE-C / 709 / 601（不写的话解码器按尺寸猜：小图猜这一套、2560×1440 的底猜 709，两套混在一张画面里预览会偏
/// 七八级，和透明无关）。不写死 709：预乘副本要照抄解码器标的，写死 709 的副本会偏 10 级 —— 这一条要能抓住。
let alphaColors: [String: String] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
]

private struct AlphaFixture {
    var name: String
    var url: URL
    /// 文件里存的是预乘还是直通的颜色。
    var stored: SourceAlpha
    /// SkyCut 该认成什么（没写标记的按预乘）。
    var recognised: SourceAlpha
    /// 这一份要跑全部组合（别的只跑静态那一条）。
    var full: Bool
}

/// 一个组合：这一段怎么改、叠的时候额外乘多少（不透明度 / 渐变走到哪）、在哪取。
private struct AlphaScenario {
    var name: String
    var opacity = 1.0
    var onMain = false
    var at = 1.0
    var scale = 1.0
    /// 摆小到画布的这么大（居中）；1 = 铺满。
    var placed = 1.0
    var hardware = false
    var change: (inout EditClip) -> Void = { _ in }
}

private let alphaScenarios: [AlphaScenario] = [
    AlphaScenario(name: "上层轨（静态）"),
    AlphaScenario(name: "不透明度 0.6", opacity: 0.6) { $0.opacity = 0.6 },
    AlphaScenario(name: "渐入走到一半", opacity: 0.5, at: 0.5) { $0.videoFadeInDuration = 1 },
    AlphaScenario(name: "奇数边裁切 + 缩到一半", placed: 0.5) {
        $0.crop = ClipCrop(top: 1 / 180, bottom: 0, leading: 0, trailing: 0)
        $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
    },
    AlphaScenario(name: "关键帧（fill + matte 预渲染）") {
        var animation = ClipAnimation()
        animation.opacity = KeyframeTrack(keys: [Keyframe(time: 0, value: 1), Keyframe(time: 2, value: 1)])
        $0.animation = animation
    },
    AlphaScenario(name: "入场动画（预渲染）") {
        $0.presetAnimation.entrance = .zoom
        $0.videoFadeInDuration = 0.3
    },
    AlphaScenario(name: "单独在 V1（底下是黑）", onMain: true),
    AlphaScenario(name: "V1 + 不透明度 0.6", opacity: 0.6, onMain: true) { $0.opacity = 0.6 },
    AlphaScenario(name: "老段（没记标记，渲染的入口补认）") { $0.info?.alpha = nil },
    AlphaScenario(name: "2560×1440 的画布", scale: 8),
    AlphaScenario(name: "硬件编码", hardware: true),
]

func checkAlphaSources(white: URL, info: MediaInfo) async {
    await checkAlphaStill(white: white, info: info)
    await checkAlphaVideo()
}

private func checkAlphaVideo() async {
    guard let red = await makeColorVideo("alpha-red.mp4", rgb: [220, 40, 40], size: alphaSize),
          let redLarge = await makeColorVideo("alpha-red-1440.mp4", rgb: [220, 40, 40], size: CGSize(width: 2560, height: 1440)),
          let blue = await makeColorVideo("alpha-proxy-blue.mp4", rgb: [0, 0, 255], size: alphaSize),
          let redInfo = await probedInfo(red), let redLargeInfo = await probedInfo(redLarge) else {
        check(false, "带透明的视频：底片做不出来")
        return
    }
    check(redInfo.alpha == .opaque, "不透明的 H.264：认成不透明（实测 \(String(describing: redInfo.alpha))）")

    var fixtures: [AlphaFixture] = []
    var skipped: [String] = []
    let plans: [(String, AVVideoCodecType, Bool, Bool, SourceAlpha, Bool)] = [
        ("prores-premult.mov", .proRes4444, true, true, .premultiplied, true),
        ("prores-straight.mov", .proRes4444, false, true, .straight, true),
        ("prores-untagged.mov", .proRes4444, true, false, .premultiplied, false),
        ("hevc-premult.mov", .hevcWithAlpha, true, true, .premultiplied, false),
        ("hevc-straight.mov", .hevcWithAlpha, false, true, .straight, true),
    ]
    for (name, codec, premultiplied, tag, recognised, full) in plans {
        guard let url = await makeAlphaVideo(name, codec: codec, premultiplied: premultiplied, tag: tag) else {
            // CI 的 runner 上可能没有 HEVC 带透明的编码器：明说跳过了什么，不算过。
            skipped.append(name)
            print("SKIP 带透明的视频：这台机器写不出 \(name)（VideoToolbox 没有这个编码器），这一份的组合都没跑")
            continue
        }
        fixtures.append(AlphaFixture(name: name, url: url, stored: premultiplied ? .premultiplied : .straight, recognised: recognised, full: full))
    }
    check(fixtures.contains { $0.name.hasPrefix("prores") }, "ProRes 4444 的三份都做得出来（AVFoundation 自带的编码器）")

    for fixture in fixtures {
        guard let info = await probedInfo(fixture.url) else {
            check(false, "\(fixture.name)：探不出媒体信息")
            continue
        }
        check(info.alpha == fixture.recognised, "\(fixture.name)：认成\(fixture.recognised)（实测 \(String(describing: info.alpha))）")
        await checkCopies(fixture)
        guard let previewSource = await readerBands(fixture.url), let exportSource = ffmpegBands(fixture.url, name: fixture.name) else {
            check(false, "\(fixture.name)：解不出参考色")
            continue
        }
        let previewOverlay = premultipliedBands(previewSource, stored: fixture.stored)
        let exportOverlay = premultipliedBands(exportSource, stored: fixture.stored)
        for scenario in alphaScenarios where fixture.full || scenario.name == alphaScenarios[0].name {
            await runAlphaScenario(scenario, fixture: fixture, info: info, base: scenario.scale > 1 ? (redLarge, redLargeInfo) : (red, redInfo),
                                   previewOverlay: previewOverlay, exportOverlay: exportOverlay)
        }
        if fixture.full { await checkProxyIgnored(fixture, info: info, red: red, redInfo: redInfo, blue: blue, previewOverlay: previewOverlay) }
        for kind in [AlphaSourceCopies.Kind.premultiplied, .matte] {
            if let copy = AlphaSourceCopies.cacheURL(kind, for: fixture.url) { try? FileManager.default.removeItem(at: copy) }
        }
    }
    if !skipped.isEmpty { print("SKIP 带透明的视频：没跑的文件 \(skipped.joined(separator: "、"))（上面写了原因）") }
}

private func runAlphaScenario(
    _ scenario: AlphaScenario, fixture: AlphaFixture, info: MediaInfo, base: (url: URL, info: MediaInfo),
    previewOverlay: [[Double]], exportOverlay: [[Double]]
) async {
    var clip = EditClip(sourceURL: fixture.url, sourceDuration: 2, timelineStart: 0, info: info)
    scenario.change(&clip)
    var state = TimelineState()
    if scenario.onMain {
        state.mainClips = [clip]
    } else {
        state.mainClips = [EditClip(sourceURL: base.url, sourceDuration: 2, timelineStart: 0, info: base.info)]
        state.overlayTracks = [EditLane(clips: [clip])]
    }
    let canvas = CGSize(width: alphaSize.width * scenario.scale, height: alphaSize.height * scenario.scale)
    // 带的中心落到画布上哪：缩到一半的那一条摆在正中间。
    let points = bandCenters.map { p in
        CGPoint(x: ((p.x - alphaSize.width / 2) * scenario.placed + alphaSize.width / 2) * scenario.scale,
                y: ((p.y - alphaSize.height / 2) * scenario.placed + alphaSize.height / 2) * scenario.scale)
    }
    let label = "\(fixture.name) · \(scenario.name)"
    if !scenario.hardware {
        if let codes = await previewCodes(state, points: points, at: scenario.at),
           let underneath = await baseColor(scenario, base: base, preview: true, settings: VideoEncodeSettings(), at: points[0]) {
            compareBands(codes, base: underneath, overlay: previewOverlay, opacity: scenario.opacity, label: "预览 · \(label)")
        } else {
            check(false, "预览 · \(label)：取不出帧")
        }
    }
    var settings = VideoEncodeSettings()
    if scenario.hardware { settings.encoder = .hardware }
    let name = "alpha-\(fixture.name)-\(alphaScenarios.firstIndex { $0.name == scenario.name } ?? 0).mp4"
    guard let product = await export(state, name: name, settings: settings, allowFailure: scenario.hardware) else {
        if scenario.hardware { print("SKIP 带透明的视频 · \(label)：这台机器的 h264_videotoolbox 用不了，硬件编码这一条没跑") }
        return
    }
    if let codes = exportCodes(product, points: points, at: scenario.at, canvas: canvas, name: name),
       let underneath = await baseColor(scenario, base: base, preview: false, settings: settings, at: points[0]) {
        compareBands(codes, base: underneath, overlay: exportOverlay, opacity: scenario.opacity, label: "成片 · \(label)")
    }
}

/// 只放底片（不放上层段）时，这条管线在这一点量到的码值 —— 参考里的底色。单独在 V1 的段底下是画布的黑。按管线 / 画布 / 编码器记住。
private var measuredBases: [String: [Double]] = [:]
private func baseColor(
    _ scenario: AlphaScenario, base: (url: URL, info: MediaInfo), preview: Bool, settings: VideoEncodeSettings, at point: CGPoint
) async -> [Double]? {
    if scenario.onMain { return [0, 0, 0] }
    let key = "\(preview)-\(scenario.scale)-\(settings.encoder == .hardware)"
    if let known = measuredBases[key] { return known }
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: base.url, sourceDuration: 2, timelineStart: 0, info: base.info)]
    let canvas = CGSize(width: alphaSize.width * scenario.scale, height: alphaSize.height * scenario.scale)
    let name = "alpha-base-\(scenario.scale)-\(settings.encoder == .hardware).mp4"
    let measured: [Double]?
    if preview {
        measured = await previewCodes(state, points: [point], at: 1)?.first
    } else if let product = await export(state, name: name, settings: settings) {
        measured = exportCodes(product, points: [point], at: 1, canvas: canvas, name: name)?.first
    } else {
        measured = nil
    }
    if measured == nil { check(false, "带透明的视频：只放底片的\(preview ? "预览" : "成片")量不出底色") }
    measuredBases[key] = measured
    return measured
}

/// 四条带和参考比：参考 = 预乘色 × 不透明度 + 底色 ×（1 − alpha × 不透明度）。全透明那条带的参考就是底色。
private func compareBands(_ codes: [[Double]], base: [Double], overlay: [[Double]], opacity: Double, label: String) {
    var worst = 0.0
    for (band, measured) in codes.enumerated() {
        let alpha = overlay[band][3] / 255 * opacity
        for channel in 0..<3 {
            let expected = overlay[band][channel] * opacity + base[channel] * (1 - alpha)
            worst = max(worst, abs(measured[channel] - expected))
        }
    }
    check(worst <= alphaTolerance, "\(label)：半透明处和参考最多差 \(Int(worst.rounded())) 级（容差 \(Int(alphaTolerance))）实测 \(codes.map { $0.map { Int($0) } })")
}

/// 两份副本：直通的源转成预乘的（标明预乘、颜色乘过 alpha、和原片一样长），遮罩是 alpha 的灰度。
private func checkCopies(_ fixture: AlphaFixture) async {
    guard fixture.full, let source = await readerBands(fixture.url) else { return }
    let sourceDuration = (try? await AVURLAsset(url: fixture.url).load(.duration).seconds) ?? 0
    if fixture.stored == .straight {
        if let copy = await AlphaSourceCopies.url(.premultiplied, for: fixture.url), let bands = await readerBands(copy),
           let copyInfo = await probedInfo(copy) {
            check(copyInfo.alpha == .premultiplied, "\(fixture.name) 的预乘副本：文件里标明预乘（实测 \(String(describing: copyInfo.alpha))）")
            check(abs(copyInfo.duration - sourceDuration) < 0.001, "\(fixture.name) 的预乘副本和原片一样长（\(copyInfo.duration) / \(sourceDuration)）")
            let expected = premultipliedBands(source, stored: .straight)
            let worst = zip(bands, expected).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 99
            check(worst <= 3, "\(fixture.name) 的预乘副本：颜色乘过了 alpha，最多差 \(worst) 级（实测 \(bands)）")
        } else {
            check(false, "\(fixture.name)：转不出预乘副本")
        }
    }
    if let matte = await AlphaSourceCopies.url(.matte, for: fixture.url), let bands = await readerBands(matte) {
        let worst = zip(bands, source).map { pair in pair.0.prefix(3).map { abs($0 - pair.1[3]) }.max() ?? 0 }.max() ?? 99
        check(worst <= 3 && bands.allSatisfy { $0[3] == 255 }, "\(fixture.name) 的遮罩：灰度 = alpha、不透明，最多差 \(worst) 级（实测 \(bands)）")
    } else {
        check(false, "\(fixture.name)：抽不出遮罩")
    }
}

/// 优化媒体：带透明的源不转代理；就算表上有它的块（老工程转过的），builder 也不许换进来（代理是 H.264，没有 alpha）。
private func checkProxyIgnored(_ fixture: AlphaFixture, info: MediaInfo, red: URL, redInfo: MediaInfo, blue: URL, previewOverlay: [[Double]]) async {
    var longGOP = info
    longGOP.keyframeInterval = 10
    longGOP.videoCodec = "hvc1"
    check(!OptimizedMediaPolicy.needsProxy(info: longGOP, isStillImage: false, decodeFPS: 100),
          "\(fixture.name)：带透明的源不转代理（长 GOP 也不转）")
    longGOP.alpha = .opaque
    check(OptimizedMediaPolicy.needsProxy(info: longGOP, isStillImage: false, decodeFPS: 100), "同样的长 GOP 不透明的源照转（对照）")
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: red, sourceDuration: 2, timelineStart: 0, info: redInfo)]
    state.overlayTracks = [EditLane(clips: [EditClip(sourceURL: fixture.url, sourceDuration: 2, timelineStart: 0, info: info)])]
    let lookup = OptimizedMediaLookup(chunks: [fixture.url: [0: blue]])
    if let codes = await previewCodes(state, points: bandCenters, at: 1, proxies: lookup),
       let underneath = await baseColor(alphaScenarios[0], base: (red, redInfo), preview: true, settings: VideoEncodeSettings(), at: bandCenters[0]) {
        compareBands(codes, base: underneath, overlay: previewOverlay, opacity: 1, label: "预览 · \(fixture.name) · 表上有它的块（不许换进来）")
    } else {
        check(false, "预览 · \(fixture.name) · 表上有它的块：取不出帧")
    }
}

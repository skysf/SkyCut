import CoreGraphics
import Foundation
import SrtFlowCore

// 真导出：开着水印和不开各导一遍（同一份素材、同一条管线，只差水印），抽帧逐像素比：
// 1. 每一段改动的外接框落在表上那一处的整张图里，范围差不多是整个 logo；
// 2. 段的边界上正好换（24 fps：第 95 帧 = 3.958 秒还是第一段，第 96 帧 = 4.000 秒已经是第二段）；
// 3. 压在形状之上（整幅实心的形状盖满画面，水印照样在）；
// 4. 不加水印时滤镜图里一点水印都没有；
// 5. 缩到导出分辨率之后还在那一角（按工程尺寸叠完再整幅缩小）。

private let canvas = CGSize(width: 640, height: 360)
private let seed: UInt64 = 20_261_027

private func clipState(_ url: URL, size: CGSize, seconds: Double) -> TimelineState {
    var state = TimelineState()
    let info = MediaInfo(
        duration: seconds, displaySize: size, frameRate: 24, videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
    state.mainClips = [EditClip(sourceURL: url, sourceDuration: seconds, timelineStart: 0, info: info)]
    return state
}

/// 表上那一处的整张图（含阴影那一圈）在画面上占的框。
private func expectedBox(_ spot: WatermarkPlacement.Spot, logo: WatermarkImage.Logo, canvas: CGSize) -> CGRect? {
    let width = WatermarkPlacement.logoWidth(spot, canvas: canvas)
    guard let image = WatermarkImage.render(logo, logoWidth: width, opacity: WatermarkPlacement.opacity) else { return nil }
    let ink = WatermarkPlacement.inkOrigin(spot, ink: image.inkSize, canvas: canvas)
    return CGRect(x: ink.x - image.inset, y: ink.y - image.inset, width: image.pixelSize.width, height: image.pixelSize.height)
}

/// 这一帧的水印落在 `box` 里、差不多是整个 logo。
private func checkMark(base: Frame, marked: Frame, box: CGRect, label: String) {
    guard let changes = marked.changes(from: base, threshold: 24) else {
        check(false, "\(label)：一个像素都没变，水印没叠上")
        return
    }
    check(box.insetBy(dx: -2, dy: -2).contains(changes.box), "\(label)：改动 \(changes.box) 落在那一处的图 \(box) 里")
    check(changes.box.width >= box.width * 0.6 && changes.box.height >= box.height * 0.5, "\(label)：改动差不多是整个 logo：\(changes.box)")
    check(changes.count > 300, "\(label)：logo 的像素够多：\(changes.count)")
}

func runExportChecks(logo: WatermarkImage.Logo) async {
    let mark = ExportWatermark(logo: logo, seed: seed)
    let slots = WatermarkPlacement.schedule(total: 10, seed: seed)
    guard slots.count == 3, let gray = makeVideo("gray.mp4", graph: "color=c=0x808080:s=640x360:r=24:d=10") else {
        check(false, "10 秒的表应有三段、灰底素材要造得出来")
        return
    }
    let state = clipState(gray, size: canvas, seconds: 10)

    // ---- 1、2. 每一段那一处，边界上正好换
    if let baseline = await export(state, name: "base.mp4", watermark: nil),
       let product = await export(state, name: "marked.mp4", watermark: mark) {
        for (number, index) in [(48, 0), (95, 0), (96, 1), (144, 1), (216, 2)] {
            guard let fb = frame(baseline, number: number, size: canvas, name: "base"),
                  let fm = frame(product, number: number, size: canvas, name: "marked"),
                  let box = expectedBox(slots[index].spot, logo: logo, canvas: canvas) else { continue }
            checkMark(base: fb, marked: fm, box: box, label: "第 \(number) 帧（第 \(index) 段，\(slots[index].spot)）")
        }
    }

    // ---- 3. 压在形状之上：整幅实心的黄色形状盖满画面
    var covered = state
    var fill = ShapeAnnotation(kind: .rectangle, timelineStart: 0, duration: 10, color: .yellow, width: 1, height: 1)
    fill.isFilled = true
    covered.shapes = [fill]
    if let baseline = await export(covered, name: "shape-base.mp4", watermark: nil),
       let product = await export(covered, name: "shape-marked.mp4", watermark: mark),
       let fb = frame(baseline, number: 48, size: canvas, name: "shape-base"),
       let fm = frame(product, number: 48, size: canvas, name: "shape-marked"),
       let box = expectedBox(slots[0].spot, logo: logo, canvas: canvas) {
        checkMark(base: fb, marked: fm, box: box, label: "盖满画面的形状上面")
    }

    // ---- 4. 不加水印时滤镜图里一点都没有；加的时候两张图只叠两层
    let output = root.appendingPathComponent("args.mp4")
    if let plain = try? await VideoEditExportGraph.plan(
        state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil,
        output: output, watermark: nil
    ), let marked = try? await VideoEditExportGraph.plan(
        state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil,
        output: output, watermark: mark
    ) {
        defer { try? FileManager.default.removeItem(at: plain.workspace); try? FileManager.default.removeItem(at: marked.workspace) }
        check(!plain.arguments.contains { $0.hasSuffix("watermark-corner.png") || $0.hasSuffix("watermark-center.png") },
              "不加水印：参数里没有水印的图")
        let used = Set(slots.map { $0.spot.isCorner })
        let inputs = marked.arguments.filter { $0.hasSuffix("watermark-corner.png") || $0.hasSuffix("watermark-center.png") }
        check(inputs.count == used.count, "加水印：表里用到几种（四角 / 正中）就进几张图：\(inputs.count)，应 \(used.count)")
    }

    // ---- 5. 缩小之后还在那一角：1280 × 720 的工程导 480p（854 × 480）
    let big = CGSize(width: 1280, height: 720)
    if let source = makeVideo("gray-720.mp4", graph: "color=c=0x808080:s=1280x720:r=24:d=4") {
        var settings = VideoEncodeSettings()
        settings.resolution = .sd480
        let small = clipState(source, size: big, seconds: 4)
        let first = WatermarkPlacement.schedule(total: 4, seed: seed)[0].spot
        let scaled = CGSize(width: 854, height: 480)
        if let baseline = await export(small, name: "small-base.mp4", watermark: nil, settings: settings),
           let product = await export(small, name: "small-marked.mp4", watermark: mark, settings: settings),
           let fb = frame(baseline, number: 48, size: scaled, name: "small-base"),
           let fm = frame(product, number: 48, size: scaled, name: "small-marked"),
           let full = expectedBox(first, logo: logo, canvas: big) {
            let ratio = scaled.width / big.width
            let box = CGRect(x: full.minX * ratio, y: full.minY * ratio, width: full.width * ratio, height: full.height * ratio).insetBy(dx: -2, dy: -2)
            checkMark(base: fb, marked: fm, box: box, label: "缩到 480p 之后（\(first)）")
        }
    }
}

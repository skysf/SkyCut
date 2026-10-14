import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// 主轨接缝上的推移 / 擦除 / 黑场 / 白场在预览（也就是 AI 的 look）里长得和成片一样（docs/architecture/preview-free-transform.md）。
// 推移 / 擦除这一组（P1–P5）2026-10-14 从 main.swift 原样搬过来（那个文件超过 600 行、只许降）；
// 黑场 / 白场照 xfade 的曲线（X1–X3）、带关键帧的段推移（P6–P7）是同一天加的
// （docs/bugfixes/2026-10-14-look-transitions-differ-from-export.md）。

func checkSeamTransitionLooks(white1: URL, root: URL) async throws {
    let black1 = try await makeSolidVideo(white: 0, seconds: 4, name: "black1.mp4")
    let halfTone = try await makeHalfToneVideo(seconds: 4, name: "halftone.mp4")
    let leftBand = CGRect(x: 0.05, y: 0.1, width: 0.35, height: 0.8)
    let rightBand = CGRect(x: 0.6, y: 0.1, width: 0.35, height: 0.8)
    let topBand = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.35)
    let bottomBand = CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.35)

    // P1. 左推方向：白→黑，中点左半是还没滑走的出场段（白）、
    //     右半是从右边滑进来的进场段（黑）。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(white1, black1, kind: .pushLeft)
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        let right = await regionBrightness(built, at: 3.5, region: rightBand)
        check(left > 0.85, "左推中点左半应是出场段（白），实测 \(left)")
        check(right < 0.15, "左推中点右半应是进场段（黑），实测 \(right)")
    } else {
        check(false, "左推场景合成失败")
    }

    // P2. 右推方向相反：中点左黑右白。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(white1, black1, kind: .pushRight)
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        let right = await regionBrightness(built, at: 3.5, region: rightBand)
        check(left < 0.15, "右推中点左半应是进场段（黑），实测 \(left)")
        check(right > 0.85, "右推中点右半应是出场段（白），实测 \(right)")
    } else {
        check(false, "右推场景合成失败")
    }

    // P3. 下擦除：进场段从顶上露出来 → 中点上黑下白。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(white1, black1, kind: .wipeDown)
    ) {
        let top = await regionBrightness(built, at: 3.5, region: topBand)
        let bottom = await regionBrightness(built, at: 3.5, region: bottomBand)
        check(top < 0.15, "下擦除中点上半应是进场段（黑），实测 \(top)")
        check(bottom > 0.85, "下擦除中点下半应是出场段（白），实测 \(bottom)")
    } else {
        check(false, "下擦除场景合成失败")
    }

    // P4. 推移 vs 擦除的本质区别（两色探针，出场段左白右黑、进场段全黑）：
    //     中点画布左半边 —— 擦除显示出场段**自己的左半**（白），
    //     左推显示的是**滑过来的右半**（黑）。纯色素材下两者长得一样，
    //     这一对探针就是防「擦除写成了滑动」（或反过来）的。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(halfTone, black1, kind: .wipeLeft)
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        check(left > 0.85, "左擦除中点左半应是出场段原位的左半（白），实测 \(left)")
    } else {
        check(false, "左擦除两色场景合成失败")
    }
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(halfTone, black1, kind: .pushLeft)
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        check(left < 0.15, "左推中点左半应是滑过来的出场段右半（黑），实测 \(left)")
    } else {
        check(false, "左推两色场景合成失败")
    }

    // P5. 回退：任意角旋转的出场段不满足推移的精确前提 → 双向淡变，
    //     不许出现硬切边（左右两半亮度要接近），也不许全亮。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(white1, black1, kind: .pushLeft) { $0.rotationDegrees = 30 }
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        let right = await regionBrightness(built, at: 3.5, region: rightBand)
        check(
            abs(left - right) < 0.3,
            "旋转段左推应回退成淡变（无滑动分界），实测左 \(left) 右 \(right)"
        )
        check(left < 0.8, "旋转段左推回退路径中点不该全亮，实测 \(left)")
    } else {
        check(false, "旋转段左推场景合成失败")
    }

    try await checkFadeToColorCurves(root: root)
    try await checkPushWithKeyframedSide(white1: white1, black1: black1, root: root)
}

/// X1–X3：黑场 / 白场。两侧都满幅不透明时，预览照 ffmpeg xfade 的 fadeblack / fadewhite 逐帧算（成片就是 xfade）：
/// 窗口里每一帧的亮度 = `XfadeColorCurve.ffmpegMix`。有一侧缩小（盖不满）时退回半程模型，但闪白仍是淡向白 ——
/// 以前垫的只有黑底，闪白在预览和 AI 的 look 里成了黑场。
private func checkFadeToColorCurves(root: URL) async throws {
    let gray = try await makeSolidVideo(white: 0.5, seconds: 4, name: "x-gray.mp4")
    let dark = try await makeSolidVideo(white: 0.25, seconds: 4, name: "x-dark.mp4")
    // 两段单独放在时间线上量出来的亮度（编解码会让 0.5 / 0.25 偏一点：实测 0.54 / 0.28），公式拿它们算。
    func solo(_ url: URL) async -> Double {
        let info = MediaInfo(
            duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
            videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
        )
        var state = TimelineState()
        state.mainClips = [EditClip(sourceURL: url, sourceDuration: 4, timelineStart: 0, info: info)]
        guard let built = await VideoEditCompositionBuilder.build(from: state) else { return -1 }
        return await exactBrightness(built, atTick: 1200)
    }
    let a = await solo(gray)
    let b = await solo(dark)
    check(a > 0.4 && b > 0.15 && a > b, "黑场 / 白场：两段素材量得出来（\(a) / \(b)）")
    for (kind, color) in [(ClipTransition.whiteFade, 1.0), (.blackFade, 0.0)] {
        guard let built = await VideoEditCompositionBuilder.build(from: seamState(gray, dark, kind: kind)) else {
            check(false, "\(kind) 场景合成失败")
            continue
        }
        // 窗口 3.0–4.0 秒（seamState：前段 0–4、后段 3 起），24 fps 的格子上取正好那一帧。
        for progress in [0.125, 0.25, 0.5, 0.75] {
            let measured = await exactBrightness(built, atTick: Int64(((3 + progress) * 600).rounded()))
            let expected = XfadeColorCurve.ffmpegMix(a: a, b: b, color: color, progress: progress)
            check(abs(measured - expected) < 0.03,
                  "\(kind) 进行到 \(progress) 时该和成片的 xfade 一样亮 \(String(format: "%.3f", expected))，实测 \(String(format: "%.3f", measured))")
        }
    }
    // X3. 出场段缩小一半（盖不满）：退回半程模型，中点那一刻两段都看不见，露出来的是白底（不是黑底）。
    let shrunk = seamState(gray, dark, kind: .whiteFade) {
        $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
    }
    if let built = await VideoEditCompositionBuilder.build(from: shrunk) {
        let mid = await exactBrightness(built, atTick: 2100)
        check(mid > 0.9, "盖不满的闪白，中点露出来的该是白底，实测 \(mid)")
    } else {
        check(false, "盖不满的闪白场景合成失败")
    }
}

/// P6–P7：带关键帧的段（跟拍铺满的竖屏片子里每段都是）推移也是真的滑动，不再回退成双向淡变（那在预览和 look 里像叠化）。
private func checkPushWithKeyframedSide(white1: URL, black1: URL, root: URL) async throws {
    let leftBand = CGRect(x: 0.05, y: 0.1, width: 0.35, height: 0.8)
    let rightBand = CGRect(x: 0.6, y: 0.1, width: 0.35, height: 0.8)
    func keyframed(_ clip: inout EditClip, width: Double) {
        var animation = ClipAnimation()
        animation.centerX.set(0.5, atSourceTime: 0, tolerance: kfTol)
        animation.centerX.set(0.52, atSourceTime: 4, tolerance: kfTol)
        animation.width.set(width, atSourceTime: 0, tolerance: kfTol)
        animation.width.set(width, atSourceTime: 4, tolerance: kfTol)
        animation.height.set(width, atSourceTime: 0, tolerance: kfTol)
        animation.height.set(width, atSourceTime: 4, tolerance: kfTol)
        clip.animation = animation
    }
    // P6. 出场段（白）带位置关键帧、放大一点盖满画布：左推中点左半是出场段、右半是滑进来的进场段（黑）。
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(white1, black1, kind: .pushLeft) { keyframed(&$0, width: 1.2) }
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        let right = await regionBrightness(built, at: 3.5, region: rightBand)
        check(left > 0.85, "带关键帧的段左推：中点左半应是出场段（白），实测 \(left)")
        check(right < 0.15, "带关键帧的段左推：中点右半应是进场段（黑），实测 \(right)")
    } else {
        check(false, "带关键帧的段左推场景合成失败")
    }
    // P7. 压平到画布：出场段（左白右黑）放大到两倍，画面里看得见的是中间那一截。滑走时画布外的那一截（源的最右边，黑）
    //     不许跟着滑进画面 —— 右半要是进场段（白），左半是原来看得见的右半（黑）。裁切每片按那一刻的摆放算。
    let halfTone = try await makeHalfToneVideo(seconds: 4, name: "p7-halftone.mp4")
    if let built = await VideoEditCompositionBuilder.build(
        from: seamState(halfTone, white1, kind: .pushLeft) { keyframed(&$0, width: 2) }
    ) {
        let left = await regionBrightness(built, at: 3.5, region: leftBand)
        let right = await regionBrightness(built, at: 3.5, region: rightBand)
        check(left < 0.15, "放大的关键帧段左推：中点左半应是滑过来的、原来看得见的右半（黑），实测 \(left)")
        check(right > 0.85, "放大的关键帧段左推：中点右半应是进场段（白），画布外那一截不许滑进来，实测 \(right)")
    } else {
        check(false, "放大的关键帧段左推场景合成失败")
    }
}

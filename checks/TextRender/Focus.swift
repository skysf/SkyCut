import CoreGraphics
import Foundation

// 第 17 组：对焦（focus）入场 / 出场 —— 边缓缓放大、边从模糊收清。2026-10-14 从 main.swift 原样搬出来（那个文件超过了 600 行的上限，
// docs/architecture/coding-standards.md），编法见 scripts/check-text-render.sh。

func checkFocusAnimation() {
    //
    // 三条契约，每一条都对应一个当时拍板的决定：
    //   · 终点**精确**收口（缩放到 1、模糊到 0、不透明度到 1）——
    //     差一点点就是"停在略糊略小的位置"，标题上极显眼；
    //   · 曲线**接近匀速**，不是别的入场用的 easeOutCubic ——
    //     后者把动作压在前三分之一，观感是"弹进来"，正好不是"缓慢"；
    //   · 起手不透明度**可调**，两头分别是"相机对焦"和"纯淡入"。

    var focusing = whiteTitle(start: 0, duration: 4)
    focusing.animation = TextAnimation(
        entrance: .focus, exit: .focus,
        entranceDuration: 1, exitDuration: 1,
        emphasis: .none, intensity: 0.8, focusStartOpacity: 0.35
    )

    func focusState(_ overlay: TextOverlay, at time: Double) -> TextAnimationState {
        TextAnimator.state(for: overlay, at: time, canvas: canvas, frameRate: .fps30)
    }

    let inStart = focusState(focusing, at: 0)
    let inMid = focusState(focusing, at: 0.5)
    // **量入场窗口里的最后一帧，不是窗口边界**：`t == 入场时长` 那一刻已经
    // 出了窗口，拿到的是静止态，断言就成了空的（第一版就是这么写的，
    // 把"缩放停在 0.98"的破坏改动放了过去）。
    let inLast = focusState(focusing, at: 1 - 1.0 / 30)
    let afterIn = focusState(focusing, at: 1)

    check(inStart.scale < 0.95, "入场起手要明显缩小，实际 \(inStart.scale)")
    check(inStart.blur > 1, "入场起手要明显模糊，实际 \(inStart.blur)")
    checkClose(inStart.opacity, 0.35, 0.001, "入场起手的不透明度等于设定的起手值")
    checkClose(inLast.scale, 1, 0.005, "入场最后一帧缩放已经收到 1")
    checkClose(inLast.blur, 0, 0.15, "入场最后一帧模糊已经收到 0")
    checkClose(inLast.opacity, 1, 0.01, "入场最后一帧完全不透明")
    check(afterIn.isIdentity, "入场窗口之外必须是静止态（中间那段才能当一张图导出）")

    // 曲线接近匀速的判据：中点正好落在两端的**中间**。
    // 不写死幅度常量 —— 那样改幅度就得改断言，而这里要守的是曲线形状。
    // easeOutCubic 的中点是 0.875，这两条会当场红。
    checkClose(inMid.scale, (inStart.scale + 1) / 2, 0.01,
               "缩放的中点要落在两端正中（曲线接近匀速，不是先快后慢）")
    checkClose(inMid.blur, inStart.blur / 2, 0.02 * max(1, inStart.blur),
               "模糊的中点要落在两端正中")

    // 出场**继续放大**（镜头一直往前推，最后失焦），不是缩回去。
    let outMid = focusState(focusing, at: 3.5)
    let outEnd = focusState(focusing, at: 3.999)
    check(outEnd.scale > 1.05, "出场要继续放大（不是缩回去），实际 \(outEnd.scale)")
    check(outEnd.blur > 1, "出场要糊掉，实际 \(outEnd.blur)")
    checkClose(outMid.scale, (1 + outEnd.scale) / 2, 0.02,
               "出场的缩放中点同样落在两端正中")

    // 速度可调：状态只由**相对进度**决定，不由绝对时间决定。
    // 写错成"按绝对秒数算"的话，改时长动画就会被截断或播不完。
    var slower = focusing
    slower.animation.entranceDuration = 3
    let slowMid = focusState(slower, at: 1.5)
    checkClose(slowMid.scale, inMid.scale, 0.001, "时长变了，同一相对进度处的缩放不变")
    checkClose(slowMid.blur, inMid.blur, 0.001, "时长变了，同一相对进度处的模糊不变")
    checkClose(slowMid.opacity, inMid.opacity, 0.001, "时长变了，同一相对进度处的不透明度不变")

    // 起手不透明度的两头。
    var opaqueStart = focusing
    opaqueStart.animation.focusStartOpacity = 1
    checkClose(focusState(opaqueStart, at: 0).opacity, 1, 0.001,
               "调到 100% 就是纯相机对焦：起手完全不透明，只有模糊在收")
    check(focusState(opaqueStart, at: 0).blur > 1, "调到 100% 时模糊照旧")
    var fadeStart = focusing
    fadeStart.animation.focusStartOpacity = 0
    checkClose(focusState(fadeStart, at: 0).opacity, 0, 0.001,
               "调到 0 就是从全透明淡进来")

    // 包络要同时留下模糊和出场放大的余量，否则被位图边缘切掉一条直边。
    var focusClipped: [String] = []
    for step in 0...32 {
        let time = Double(step) * 0.125
        let state = focusState(focusing, at: time)
        guard state.opacity > 0.02,
              let frame = TextRenderer.render(focusing, canvas: canvas, state: state) else { continue }
        if !borderIsClear(frame.image) { focusClipped.append(String(format: "%.2fs", time)) }
    }
    check(focusClipped.isEmpty, "对焦期间位图最外圈必须始终全透明，被裁的时刻：\(focusClipped)")

    // 只做入场对焦时，包络**不该**按出场放大留余量 —— 那会白白多出一圈空位图。
    var entranceOnly = focusing
    entranceOnly.animation.exit = .none
    let bothSizes = TextRenderer.render(focusing, canvas: canvas, state: afterIn)?.size
    let entranceSizes = TextRenderer.render(entranceOnly, canvas: canvas, state: afterIn)?.size
    if let bothSizes, let entranceSizes {
        check(entranceSizes.width < bothSizes.width,
              "只做入场对焦时位图该更小（\(entranceSizes) vs \(bothSizes)）")
    } else {
        check(false, "对焦的位图渲不出来")
    }
}

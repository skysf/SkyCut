import CoreGraphics
import Foundation
import SrtFlowCore

// 第 45 组：出场是入场倒着放、先慢后快 —— 文字、形状、画面段的入场 / 出场动画同一个口径。
// 由来（docs/bugfixes/2026-10-14-exit-animations-front-loaded.md）：2026-10-06 盲测里形状设了 2.2 秒的淡出，1 秒时已经快没了。
// 出场的 easeInCubic 作用在**剩余**进度上（出场里 reveal 从 1 倒数到 0），在时间上反倒成了先快后慢 —— 正是注释里说的
// 「不是慢慢停住」的反面。三个求值器（TextAnimator、ShapeAnimator、ClipAnimator）是同一个写法，一起钉。

private func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6, line: Int = #line) {
    check(abs(actual - expected) <= tolerance, "\(message)：得到 \(actual)，应为 \(expected)", line: line)
}

func checkExitCurves(root: URL) throws {
    // 6 秒的一段，入场、出场各 2.2 秒；出场从 3.8 秒开始。
    var shape = ShapeAnnotation(kind: .line, timelineStart: 0, duration: 6)
    shape.animation = ShapeAnimation(entrance: .fade, exit: .fade, entranceDuration: 2.2, exitDuration: 2.2)
    var text = TextOverlay(text: "南极", timelineStart: 0)
    text.duration = 6
    text.animation = TextAnimation(entrance: .fade, exit: .fade, entranceDuration: 2.2, exitDuration: 2.2, emphasis: .none, intensity: 0.6)
    let canvas = CGSize(width: 1920, height: 1080)
    func textState(_ overlay: TextOverlay, _ time: Double) -> TextAnimationState {
        TextAnimator.state(for: overlay, at: time, canvas: canvas, frameRate: .fps30)
    }
    func clipState(_ kind: ClipPresetKind, _ time: Double) -> ClipAnimationState {
        ClipAnimator.state(
            resolved: ResolvedClipPreset(entrance: kind, exit: kind, window: FadeWindow(fadeIn: 2.2, fadeOut: 2.2), intensity: 0.6),
            local: time, span: 6, coversCanvas: false
        )
    }

    // 出场开始后 1 秒（4.8 秒）：先慢，还剩九成；以前只剩一成六（症状里的「1 秒就淡完」）。
    let shapeAt1s = ShapeAnimator.state(for: shape, at: 4.8).opacity
    check(shapeAt1s > 0.85, "形状 2.2 秒的淡出，出场 1 秒时还剩九成（得到 \(shapeAt1s)）")
    check(textState(text, 4.8).opacity > 0.85, "文字 2.2 秒的淡出，出场 1 秒时还剩九成（得到 \(textState(text, 4.8).opacity)）")
    for kind in [ClipPresetKind.rise, .zoom] {
        check(clipState(kind, 4.8).opacity > 0.85, "画面段的\(kind.title)出场 1 秒时还剩九成（得到 \(clipState(kind, 4.8).opacity)）")
    }
    // 后快：最后两成时间里掉得最多。
    check(ShapeAnimator.state(for: shape, at: 5.56).opacity < 0.5, "形状淡出的最后两成时间里掉得最多")

    // 倒着放：出场离结尾 t 秒和入场离开头 t 秒一个样。
    var rising = text
    rising.animation = TextAnimation(entrance: .rise, exit: .rise, entranceDuration: 2.2, exitDuration: 2.2, emphasis: .none, intensity: 0.6)
    for t in stride(from: 0.2, through: 2.0, by: 0.3) {
        near(ShapeAnimator.state(for: shape, at: 6 - t).opacity, ShapeAnimator.state(for: shape, at: t).opacity,
             "形状的出场是入场倒着放（离两头 \(t) 秒）")
        near(textState(text, 6 - t).opacity, textState(text, t).opacity, "文字淡出是淡入倒着放（离两头 \(t) 秒）")
        // 上浮：出场继续往上走（位移反号），走的快慢和入场倒过来一样。
        near(textState(rising, 6 - t).offsetY, -textState(rising, t).offsetY, "文字上浮的出场是入场倒着放、继续往上（离两头 \(t) 秒）")
        near(clipState(.rise, 6 - t).offset.y, -clipState(.rise, t).offset.y, "画面段上浮的出场是入场倒着放（离两头 \(t) 秒）")
        near(clipState(.zoom, 6 - t).scale, clipState(.zoom, t).scale, "画面段推近的出场是入场倒着放（离两头 \(t) 秒）")
    }

    // 弹性缩放的出场不回弹：先慢后快收回去，一直在起手大小和 1 之间。
    var popShape = shape
    popShape.animation = ShapeAnimation(entrance: .pop, exit: .pop, entranceDuration: 2.2, exitDuration: 2.2)
    var previous = 1.0
    var monotonic = true
    for step in 0...22 {
        let scale = ShapeAnimator.state(for: popShape, at: 3.8 + Double(step) * 0.1).scale
        if scale > previous + 1e-9 || scale < ShapeAnimator.popStartScale - 1e-9 { monotonic = false }
        previous = scale
    }
    check(monotonic, "形状弹性缩放的出场一路收回去、不回弹")
    check(ShapeAnimator.state(for: popShape, at: 4.8).scale > 0.95, "形状弹性缩放出场 1 秒时还没怎么缩（先慢）")
}

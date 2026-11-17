import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 动效预设的一帧（小样、离屏出图）
//
// 管什么：一组字和形状在某一刻画成一张图：底色 → 形状（ShapePNGRenderer）→ 字（TextRenderer），时刻先钉到工程帧的网格上、
// 动画状态问 ShapeAnimator / TextAnimator —— 和导出叠在画面上的是同一套渲染器、同一个叠放次序（剪辑 → 形状 → 文字），
// 所以小样上看到的就是成片里的样子。加字的「动效预设」面板拿它画小样（MotionPresetPanel）。
// 不管什么：预设长什么样（MotionPresetDesign / MotionPresetGroups）、预览上怎么画（预览叠层自己画，走同一个 TextRenderer、
// ShapeOutline）。

enum MotionPresetStill {
    /// `background` = nil 时铺一块深色（小样的底：深青到深蓝，像夜里的冰面，白字看得清）。
    static func image(
        _ members: MotionPresetMembers, canvas: CGSize, at time: Double, frameRate: ProjectFrameRate,
        background: CGImage? = nil
    ) -> CGImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.draw(background, in: full)
        } else {
            fillNight(context, rect: full, space: space)
        }
        let moment = TextAnimator.quantize(time, frameRate: frameRate)
        for shape in members.shapes where !shape.isHidden && shape.contains(time: moment) {
            let state = ShapeAnimator.state(for: shape, at: moment)
            if let layer = ShapePNGRenderer.image(shape, canvas: canvas, state: state) { context.draw(layer, in: full) }
        }
        let stacked = members.texts.sorted { ($0.row, members.texts.firstIndex(of: $0) ?? 0) < ($1.row, members.texts.firstIndex(of: $1) ?? 0) }
        for overlay in stacked where !overlay.isHidden && overlay.contains(time: moment) {
            let state = TextAnimator.state(for: overlay, at: moment, canvas: canvas, frameRate: frameRate)
            guard let rendered = TextRenderer.render(overlay, canvas: canvas, state: state) else { continue }
            // RenderedText 的落点是左上原点；CG 的上下文原点在左下。
            let rect = CGRect(x: rendered.origin.x, y: canvas.height - rendered.origin.y - rendered.size.height,
                              width: rendered.size.width, height: rendered.size.height)
            context.draw(rendered.image, in: rect)
        }
        return context.makeImage()
    }

    /// 小样用的那一刻：框住再放开 = 框画完、还没放开；对焦出字 = 两行都收清之后；标题 + 数字 = 数字停下之后。
    static func showcaseTime(_ kind: MotionPresetKind, hit: Double) -> Double {
        switch kind {
        case .frameReveal: return hit + 0.75
        case .focusPull: return hit + 2.0  // 下面那行小字在「放开」那一下（1.5 秒）对焦进来
        case .titleCounter: return hit + 2.3
        }
    }

    private static func fillNight(_ context: CGContext, rect: CGRect, space: CGColorSpace) {
        let colors = [CGColor(srgbRed: 0.05, green: 0.20, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.02, green: 0.05, blue: 0.11, alpha: 1)]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) else {
            context.setFillColor(colors[1])
            context.fill(rect)
            return
        }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
}

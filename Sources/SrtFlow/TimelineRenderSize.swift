import CoreGraphics

// 当前时间线实际输出画布的纯值规则；不加载媒体、不创建合成，也不维护第二份比例算法。
// 预览 builder 与制作审查身份共用；保持既有首个 metadata、fallback 和偶数尺寸规则。
enum TimelineRenderSize {
    static func size(for state: TimelineState) -> CGSize {
        // 选了固定比例就用标准尺寸；auto 跟随第一段素材。
        if let fixed = state.canvasRatio.fixedSize { return fixed }
        let size = state.mainClips.compactMap(\.info).first?.displaySize
            ?? state.overlayTracks.flatMap(\.clips).compactMap(\.info).first?.displaySize
            ?? CGSize(width: 1920, height: 1080)
        // yuv420 的世界里宽高都得是偶数。
        return CGSize(
            width: max(2, (size.width / 2).rounded() * 2),
            height: max(2, (size.height / 2).rounded() * 2)
        )
    }
}

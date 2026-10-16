import CoreGraphics

// MARK: - 按宽高比把画面放进一块地方
//
// 管什么：剪辑页的预览框、烧录页的预览框都要「按画面的宽高比，尽量大地放进可用的那一块、不变形、不出界」。
// 以前两个视图各抄了一份一模一样的（2026-10-17 合成这一份，docs/architecture/coding-standards.md「同一条规则只有一处实现」）。
// 不管什么：画面在框里怎么摆（预览的叠层、ClipPlacement）。

enum AspectFit {
    /// 可用的地方太小（≤ 1 点）时给 1×1，免得算出 0 或负数。
    static func size(aspect: Double, in available: CGSize) -> CGSize {
        guard available.width > 1, available.height > 1 else { return CGSize(width: 1, height: 1) }
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }
}

import CoreGraphics
import Foundation

// MARK: - 画面段的四边裁切
//
// 管什么：`EditClip.crop` 这个纯值 —— 四边各裁多少、在给定尺寸上的裁切矩形、按比例居中裁，以及存盘格式。
// 不管什么：裁完的画面怎么摆（`ClipPlacement`）、预览 / 导出怎么真裁（各自的管线）。
// 2026-09-26 从 VideoEditModels.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 画面段的四边裁切：按显示方向的归一化比例。传统四边输入仍限 0…0.45；精确区域可越过此限。
/// 裁完剩下的画面填进摆放框；默认摆放框本身也按裁后的宽高比算。
struct ClipCrop: Hashable, Sendable {
    static let maximumManualInset = 0.45
    var top: Double
    var bottom: Double
    var leading: Double
    var trailing: Double

    init(top: Double = 0, bottom: Double = 0, leading: Double = 0, trailing: Double = 0) {
        self.top = min(max(top, 0), Self.maximumManualInset)
        self.bottom = min(max(bottom, 0), Self.maximumManualInset)
        self.leading = min(max(leading, 0), Self.maximumManualInset)
        self.trailing = min(max(trailing, 0), Self.maximumManualInset)
    }

    /// 原生裁切可留下任意有效矩形，不需要靠遮挡层补四边。调用方先按源像素验证最小尺寸。
    /// 保留旧 initializer 的夹紧语义，现有 crop 参数、比例预设不变。
    init?(keeping region: CGRect) {
        guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
              region.minX >= 0, region.minY >= 0, region.size.width > 0, region.size.height > 0,
              region.maxX <= 1 + 1e-12, region.maxY <= 1 + 1e-12 else { return nil }
        top = region.minY
        bottom = max(0, 1 - region.maxY)
        leading = region.minX
        trailing = max(0, 1 - region.maxX)
    }

    var exceedsLegacyLimits: Bool { max(top, bottom, leading, trailing) > Self.maximumManualInset }

    /// 检查器只改点名的一边，保住另外三边（其中可能有 region 写入的 >45%）。
    func maximumInset(at keyPath: KeyPath<ClipCrop, Double>) -> Double {
        let opposite: Double
        switch keyPath {
        case \.top: opposite = bottom
        case \.bottom: opposite = top
        case \.leading: opposite = trailing
        default: opposite = leading
        }
        return max(0, 1 - opposite - 0.000001)
    }

    func setting(_ keyPath: KeyPath<ClipCrop, Double>, to value: Double) -> ClipCrop {
        var next = self
        let value = min(max(value, 0), maximumInset(at: keyPath))
        switch keyPath {
        case \.top: next.top = value
        case \.bottom: next.bottom = value
        case \.leading: next.leading = value
        default: next.trailing = value
        }
        return next
    }

    var isEmpty: Bool {
        top <= 1e-12 && bottom <= 1e-12 && leading <= 1e-12 && trailing <= 1e-12
    }

    /// v32 及更早把小于 0.05% 的四边当作没裁；8K 下可能有数个真实像素，仅供读旧工程迁移。
    var isLegacyEmpty: Bool {
        top < 0.0005 && bottom < 0.0005 && leading < 0.0005 && trailing < 0.0005
    }

    /// 在给定显示尺寸上的裁切矩形（像素）。
    func rect(in display: CGSize) -> CGRect {
        CGRect(
            x: leading * display.width,
            y: top * display.height,
            width: max(1, display.width * (1 - leading - trailing)),
            height: max(1, display.height * (1 - top - bottom))
        )
    }

    /// 把源画面居中裁到目标宽高比（Inspector 里的比例预设）。
    static func centered(aspect: Double, in display: CGSize) -> ClipCrop {
        guard display.width > 0, display.height > 0, aspect > 0 else { return ClipCrop() }
        let current = display.width / display.height
        if current > aspect {
            // 太宽：裁左右。
            let keep = aspect / current
            let inset = (1 - keep) / 2
            return ClipCrop(leading: inset, trailing: inset)
        } else {
            // 太高：裁上下。
            let keep = current / aspect
            let inset = (1 - keep) / 2
            return ClipCrop(top: inset, bottom: inset)
        }
    }
}

extension ClipCrop: Codable {
    private enum CodingKeys: String, CodingKey {
        case top, bottom, leading, trailing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        let bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        let leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? 0
        let trailing = try c.decodeIfPresent(Double.self, forKey: .trailing) ?? 0
        // v33：有效精确区域原样往返；损坏的旧值仍沿用原来的宽容夹紧。
        self.init(top: top, bottom: bottom, leading: leading, trailing: trailing)
        if [top, bottom, leading, trailing].allSatisfy({ $0.isFinite && $0 >= 0 }),
           ClipCrop(keeping: CGRect(x: leading, y: top, width: 1 - leading - trailing, height: 1 - top - bottom)) != nil {
            self.top = top
            self.bottom = bottom
            self.leading = leading
            self.trailing = trailing
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(top, forKey: .top)
        try c.encode(bottom, forKey: .bottom)
        try c.encode(leading, forKey: .leading)
        try c.encode(trailing, forKey: .trailing)
    }
}

extension EditClip {
    /// 裁切后的源画面尺寸（显示方向）。默认摆放框按它算宽高比。
    var croppedDisplaySize: CGSize? {
        guard let display = info?.displaySize, display.width > 0, display.height > 0 else { return nil }
        guard let crop, !crop.isEmpty else { return display }
        return crop.rect(in: display).size
    }
}

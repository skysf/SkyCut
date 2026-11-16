import CoreGraphics
import Foundation

// MARK: - 画面段的自由摆放（ClipPlacement）
//
// 管什么：摆放框的值（中心 + 宽高，相对画布的 0…1）、换算成画布像素框、兜住失控的值、存盘的宽容解码。
// 不管什么：默认布局怎么算、此刻实际生效的框（`EditClip.defaultPlacement` / `resolvedPlacement`）、预览和导出怎么用它
// （docs/architecture/preview-free-transform.md）。
// 2026-11-16 从 VideoEditModels.swift 原样搬出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 画面段在输出画布上的自由摆放：中心和宽高都是相对画布的 0…1 归一化值。
///
/// `nil`（不设）表示默认布局 —— 等比铺满居中（所有视频轨同一份账）。
/// 一旦用户在预览里拖过缩放框，
/// 就换成这份显式的摆放；预览（AVFoundation 变换）和导出（ffmpeg scale+overlay）
/// 都按同一份归一化值换算，所见即所得。宽高各自独立 —— 拉边把手允许变形。
struct ClipPlacement: Hashable, Sendable {
    var centerX: Double
    var centerY: Double
    /// 相对画布宽的比例。
    var width: Double
    /// 相对画布高的比例。
    var height: Double

    /// 画布上的像素框。
    func frame(in canvas: CGSize) -> CGRect {
        CGRect(
            x: (centerX - width / 2) * canvas.width,
            y: (centerY - height / 2) * canvas.height,
            width: width * canvas.width,
            height: height * canvas.height
        )
    }

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    init(frame: CGRect, in canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else {
            self.init(centerX: 0.5, centerY: 0.5, width: 1, height: 1)
            return
        }
        self.init(
            centerX: frame.midX / canvas.width,
            centerY: frame.midY / canvas.height,
            width: frame.width / canvas.width,
            height: frame.height / canvas.height
        )
    }

    /// 兜住失控的值：尺寸别缩没，中心别整个飞出画面。
    var clamped: ClipPlacement {
        ClipPlacement(
            centerX: min(max(centerX, 0), 1),
            centerY: min(max(centerY, 0), 1),
            width: min(max(width, 0.02), 4),
            height: min(max(height, 0.02), 4)
        )
    }
}

extension ClipPlacement: Codable {
    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            centerX: try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5,
            centerY: try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

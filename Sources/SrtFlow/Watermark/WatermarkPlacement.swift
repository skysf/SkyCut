import CoreGraphics
import Foundation

// MARK: - 导出水印放在哪、多大、什么时候换（纯值）
//
// 管什么：同一时刻只在一处，每 `interval` 秒换一处，在四个角和正中之间随机挑、不连续两次落在同一处；同一个种子出同一张表
// （一次导出里能复现，不同的导出不一样；随机数是 SeededRandom）。四角的 logo 宽 = 画面短边的 25%、正中 = 15%，离边 = 短边的 4%，整体不透明度 70%。
// 数字是收费方案第 11 条定的（docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md），按工程画布算（导出时最后才整幅缩小）。
// 不管什么：图（WatermarkImage）、滤镜图（WatermarkExport）、加不加（WatermarkPolicy）。

enum WatermarkPlacement {
    enum Spot: Int, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight, center

        var isCorner: Bool { self != .center }
    }

    /// 一段 `[start, end)` 里水印在哪。
    struct Slot: Equatable, Sendable {
        let start: Double
        let end: Double
        let spot: Spot
    }

    static let interval = 4.0
    static let cornerWidth = 0.25
    static let centerWidth = 0.15
    static let margin = 0.04
    static let opacity = 0.7

    /// 整段成片的表：从 0 开始每 `interval` 秒一段，最后一段收在 `total`。
    static func schedule(total: Double, seed: UInt64, interval: Double = interval) -> [Slot] {
        guard total > 0, interval > 0 else { return [] }
        var random = SeededRandom(seed: seed)
        let count = max(1, Int((total / interval).rounded(.up)))
        var slots: [Slot] = []
        for index in 0..<count {
            let others = Spot.allCases.filter { $0 != slots.last?.spot }
            let spot = others[random.int(others.count)]
            slots.append(Slot(start: Double(index) * interval, end: min(total, Double(index + 1) * interval), spot: spot))
        }
        return slots
    }

    /// 这一处 logo 的墨迹宽（像素，取偶数、至少 2）。
    static func logoWidth(_ spot: Spot, canvas: CGSize) -> Int {
        let share = spot.isCorner ? cornerWidth : centerWidth
        return max(2, Int((min(canvas.width, canvas.height) * share / 2).rounded()) * 2)
    }

    /// 墨迹的左上角落在画面上哪（像素）：四角离两边各 `margin`，正中居中。
    static func inkOrigin(_ spot: Spot, ink: CGSize, canvas: CGSize) -> CGPoint {
        let edge = (min(canvas.width, canvas.height) * margin).rounded()
        let right = canvas.width - edge - ink.width, bottom = canvas.height - edge - ink.height
        switch spot {
        case .topLeft: return CGPoint(x: edge, y: edge)
        case .topRight: return CGPoint(x: right, y: edge)
        case .bottomLeft: return CGPoint(x: edge, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        case .center: return CGPoint(x: ((canvas.width - ink.width) / 2).rounded(), y: ((canvas.height - ink.height) / 2).rounded())
        }
    }
}

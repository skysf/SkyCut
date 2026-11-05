import SwiftUI

// MARK: - 磁吸的马蹄形图标
// 管什么：系统 SF Symbols 没有 magnet 时也能显示确认稿的磁铁轮廓；不处理开关或主题颜色。
struct TimelineMagnetSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        guard scale > 0 else { return Path() }
        let origin = CGPoint(x: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 2))
        path.addLine(to: CGPoint(x: 3, y: 9))
        path.addCurve(to: CGPoint(x: 13, y: 9), control1: CGPoint(x: 3, y: 15.7), control2: CGPoint(x: 13, y: 15.7))
        path.addLine(to: CGPoint(x: 13, y: 2))
        path.addLine(to: CGPoint(x: 9.5, y: 2))
        path.addLine(to: CGPoint(x: 9.5, y: 9))
        path.addCurve(to: CGPoint(x: 6.5, y: 9), control1: CGPoint(x: 9.5, y: 11), control2: CGPoint(x: 6.5, y: 11))
        path.addLine(to: CGPoint(x: 6.5, y: 2))
        path.closeSubpath()
        path.move(to: CGPoint(x: 3, y: 5))
        path.addLine(to: CGPoint(x: 6.5, y: 5))
        path.move(to: CGPoint(x: 9.5, y: 5))
        path.addLine(to: CGPoint(x: 13, y: 5))
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: origin.x / scale, y: origin.y / scale))
    }
}

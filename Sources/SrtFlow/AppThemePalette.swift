import AppKit
import SwiftUI

// MARK: - 界面的语义色
// 管什么：森林色的暖白 / 森林绿、时间线的低饱和色、界面的浅 / 深；经典色调用方交回原有颜色。
// 不管什么：轨道色号的分配、形状 / 文字的内容颜色、预览滤镜与导出；那些都不是界面主题。
struct AppThemePalette {
    let theme: AppTheme
    var isForest: Bool { theme == .forest }

    /// 界面的浅 / 深只有这一条：森林色固定用户确认的浅色稿，经典色跟系统（nil）。
    /// SwiftUI 的呈现根交给 `.preferredColorScheme`（AppThemeModifier）。
    var colorScheme: ColorScheme? { isForest ? .light : nil }

    /// 同一条规矩给 AppKit 自建的窗口：`.preferredColorScheme` 只改得了「宿主视图就是 contentView」的那个窗口，
    /// 宿主垫在普通 NSView 下的（提示面板）够不着，要自己设，不然系统深色时深底深字
    /// （docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md）。
    var windowAppearance: NSAppearance? {
        switch colorScheme {
        case .light?: return NSAppearance(named: .aqua)
        case .dark?: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Observation 只订阅主题；播放头和工程选择不会唤醒主题宿主。
    @MainActor static var current: Self { Self(theme: AppThemeStore.shared.theme) }

    var window: Color { isForest ? Self.color(0xf3f0e8) : Color(nsColor: .windowBackgroundColor) }
    var panel: Color { isForest ? Self.color(0xf8f6ef) : .clear }
    var previewSurround: Color { isForest ? Self.color(0xe6e5df) : .clear }
    var text: Color { isForest ? Self.color(0x19221d) : Color(nsColor: .labelColor) }
    var secondaryText: Color { isForest ? Self.color(0x676d62) : Color(nsColor: .secondaryLabelColor) }
    var accent: Color { isForest ? Self.color(0x123f32) : Color(nsColor: .controlAccentColor) }
    var toggleAccent: Color { isForest ? accent : .teal }
    var selectionFill: Color { isForest ? Self.color(0xdfe7da) : .primary.opacity(0.08) }
    var selectionStroke: Color { isForest ? accent : .white }
    var selectionGlow: Color { isForest ? .clear : .teal.opacity(0.9) }
    var waveform: Color { isForest ? Self.color(0x506447).opacity(0.8) : .white.opacity(0.72) }
    var playhead: Color { isForest ? accent : .white }
    var dragAccent: Color { isForest ? accent : .teal }

    func blockLabel(classic: Color) -> Color {
        isForest ? Self.color(0x243c2f) : classic
    }

    func laneBackground(classicOpacity: Double) -> AnyShapeStyle {
        isForest ? AnyShapeStyle(Self.color(0xebe8df)) : AnyShapeStyle(.quaternary.opacity(classicOpacity))
    }

    func subtitle(translated: Bool) -> Color {
        if isForest { return Self.color(translated ? 0xc4d7cf : 0xd3debd) }
        return translated ? .teal : .orange
    }

    func blockFill(classic: Color, kind: BlockKind) -> Color {
        guard isForest else { return classic }
        return Self.color(kind == .text ? 0xd7d3c5 : 0xc5cec0)
    }

    enum BlockKind { case text, filter }

    /// 色号仍绑定轨道身份；主题只换这一号对应的色，不按行号或素材内容重新分配。
    func trackFill(index: Int, audio: Bool, classic: Color) -> Color {
        guard isForest else { return classic }
        return Self.color(trackTone(index: index, audio: audio, accent: false))
    }

    func trackAccent(index: Int, audio: Bool, classic: Color) -> Color {
        guard isForest else { return classic }
        return Self.color(trackTone(index: index, audio: audio, accent: true))
    }

    private func trackTone(index: Int, audio: Bool, accent: Bool) -> UInt32 {
        let colors: [UInt32]
        switch (audio, accent) {
        case (false, false): colors = [0x95b3a5, 0xa6bbc2, 0xb4bdab, 0x8eaaa0, 0xb7c8be, 0xa5b3b8]
        case (false, true): colors = [0x35634f, 0x4f6c76, 0x626f53, 0x3c655b, 0x587564, 0x536c74]
        case (true, false): colors = [0xd7c0a7, 0xbdceb1, 0xd8d8b7, 0xd4b5a5, 0xc7c5a4]
        case (true, true): colors = [0x8b6546, 0x567348, 0x777b46, 0x8d6151, 0x79744b]
        }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

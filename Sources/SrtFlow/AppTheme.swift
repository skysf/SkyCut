import Foundation

// MARK: - 全 App 的界面主题与偏好
// 管什么：主题身份、缺省值和一份 UserDefaults 偏好；不进工程文件，不改变任何素材或导出颜色。
// 不管什么：SwiftUI / AppKit 的上色与窗口外观（AppThemePalette / AppThemeAppearance）。
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case forest
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forest: return "Forest (Default)"
        case .classic: return "Classic"
        }
    }

    static func restored(from value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .forest
    }
}

struct AppThemePreference {
    static let storageKey = "SrtFlow.ui.theme.v1"
    /// nil 用于脚本驱动：默认仍是正式的森林色，但测试不会覆盖用户偏好。
    let defaults: UserDefaults?

    func read() -> AppTheme {
        AppTheme.restored(from: defaults?.string(forKey: Self.storageKey))
    }

    func write(_ theme: AppTheme) {
        defaults?.set(theme.rawValue, forKey: Self.storageKey)
    }
}

/// 两套主题共用的工具图标身份；磁铁用原生 Shape，其余用 SF Symbols。
enum TimelineThemeIcons {
    static let magnet = "magnet"
    static let snapping = "arrow.right.and.line.vertical.and.arrow.left"
    static let followPlayhead = "play.square"
}

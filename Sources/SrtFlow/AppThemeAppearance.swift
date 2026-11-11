import AppKit
import Observation
import SwiftUI

// MARK: - 主题 Store 与界面宿主
// 管什么：唯一主题选择、即时刷新、原生控件的强调色、呈现根交给 SwiftUI 的浅 / 深（经典色跟着系统此刻的那一个）；
// 呈现根由 appLanguage() 统一接入。
// 不管什么：语言数据、工程 / 撤销 / 播放器状态；切主题不重建窗口，也不替换编辑器身份。
@MainActor
@Observable
final class AppThemeStore {
    static let shared = AppThemeStore(defaults: PerfCounters.isEnabled ? nil : .standard)
    private(set) var theme: AppTheme
    @ObservationIgnored private let preference: AppThemePreference

    init(defaults: UserDefaults?) {
        preference = AppThemePreference(defaults: defaults)
        theme = preference.read()
    }

    func setTheme(_ value: AppTheme) {
        guard value != theme else { return }
        preference.write(value)
        theme = value
    }
}

extension View {
    func appTheme() -> some View {
        modifier(AppThemeModifier())
    }
}

private struct AppThemeModifier: ViewModifier {
    private let store = AppThemeStore.shared

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        let palette = AppThemePalette(theme: store.theme)
        content
            .tint(palette.accent)
            .accentColor(palette.accent)
            .foregroundStyle(palette.text)
            .background(palette.isForest ? palette.window : .clear)
            .toolbarBackground(palette.panel, for: .windowToolbar)
            .toolbarBackground(palette.isForest ? .visible : .automatic, for: .windowToolbar)
            // 森林色就是用户确认的暖白稿；经典色跟系统此刻的浅 / 深（规矩只在 palette.colorScheme）。
            // 永远交明确的 .light / .dark，不交 nil：交 nil 时 SwiftUI 不撤掉之前的浅色（见 resolvedColorScheme）。
            .preferredColorScheme(palette.resolvedColorScheme(system: SystemColorScheme.shared.value))
    }
}

/// 系统此刻的浅 / 深：经典色要跟的那一个。第一次用到时才建（经典色的呈现根 body 里；森林色不读它），
/// 之后跟着 `NSApp.effectiveAppearance` 的 KVO 变 —— 用户在系统设置里切深浅色时它会变。
/// SkyCut 从不设 `NSApp.appearance`（checks/app-theme-wiring.sh 钉着），所以它读到的就是系统的。
/// 呈现根读 `value`，变了就重新交 `.preferredColorScheme`，开着的窗口、sheet 一起换。
@MainActor
@Observable
final class SystemColorScheme {
    static let shared = SystemColorScheme()
    private(set) var value: ColorScheme
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        value = Self.scheme(of: NSApplication.shared.effectiveAppearance)
        observation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            // AppKit 在主线程上换外观；回调里不碰主线程隔离的东西，下一轮再读。
            Task { @MainActor in SystemColorScheme.shared.refresh() }
        }
    }

    private func refresh() {
        let scheme = Self.scheme(of: NSApplication.shared.effectiveAppearance)
        if scheme != value { value = scheme }
    }

    /// 外观换成浅 / 深两档：高对比度的深色（accessibilityHighContrastDarkAqua）也算深色。
    nonisolated static func scheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

struct AppThemePicker: View {
    private let store = AppThemeStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Picker("Theme", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
            ForEach(AppTheme.allCases) { theme in
                Text(LocalizedStringKey(theme.title)).tag(theme)
            }
        }
        .accessibilityIdentifier("settings-theme")
    }
}

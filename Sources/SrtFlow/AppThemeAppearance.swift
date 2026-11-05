import Observation
import SwiftUI

// MARK: - 主题 Store 与界面宿主
// 管什么：唯一主题选择、即时刷新、原生控件的强调色；呈现根由 appLanguage() 统一接入。
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
            // 森林色就是用户确认的暖白稿；经典色继续跟随原来的系统浅 / 深外观。
            .preferredColorScheme(palette.isForest ? .light : nil)
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

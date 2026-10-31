import SwiftUI

// MARK: - 全 App 唯一的设置内容
//
// 管什么：设置窗口的五个分类，复用现有设置行；工具栏的 SettingsLink、应用菜单和 ⌘,
// 都由 SwiftUI Settings 场景打开这里，不再另外做语言浮层或设置副本。
// 不管什么：设置值的持久化、账号凭据、AI 客户端配置的读写。

struct SettingsWindowView: View {
    @State private var selection: SettingsCategory = .general

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 0) {
            navigation
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(selection.title))
                    .font(.title2.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                Form { content }
                    .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 750, height: 520)
        .navigationTitle("Settings")
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SettingsCategory.allCases) { category in
                Button { selection = category } label: {
                    Label(LocalizedStringKey(category.title), systemImage: category.icon)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background {
                            if selection == category {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.primary.opacity(0.08))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == category ? .isSelected : [])
                .accessibilityIdentifier("settings-category-\(category.rawValue)")
            }
            Spacer(minLength: 12)
            Text("SkyCut")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(.horizontal, 8)
        .padding(.top, 15)
        .padding(.bottom, 8)
        .frame(width: 164)
        .background(.quaternary.opacity(0.3))
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general:
            GeneralSettingsSection()
        case .ai:
            AIConnectSection()
        case .editing:
            Section { AIRecipesList() }
            Section { KokoroVoiceSettingsRow() }
        case .cache:
            OptimizedMediaSettingsSection()
        case .skyStudio:
            SkyStudioSettingsSection()
        }
    }
}

private struct GeneralSettingsSection: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Section("Interface") {
            AppLanguagePicker()
            if languageStore.needsRestartForMenus {
                Text("The app’s own text switches right away. The menu bar and system dialogs follow after you quit and reopen SkyCut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI

// MARK: - 工作台共用的设置与工具入口
//
// 管什么：更多菜单里的工具切换、后台 AI 工程入口，以及非剪辑页的返回 / 设置按钮。
// 不管什么：工程编辑器自己的按钮（VideoEditWorkbenchToolbar）、设置数据、AI 工程的停止规则。

struct WorkbenchMoreMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var state = MainWindowState.shared
    @State private var showsProjects = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Menu {
            ForEach(ToolSection.allCases.filter { $0 != .videoEdit }) { section in
                Button {
                    state.section = section
                    openWindow(id: WindowID.main)
                } label: {
                    Label(LocalizedStringKey(section.title), systemImage: section.icon)
                }
            }
            if !AIProjectsSidebarSection.projects.isEmpty {
                Divider()
                Button("AI Projects") { showsProjects = true }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.primary)
        .instantHelp("More tools")
        .accessibilityIdentifier("workbench-more")
        .popover(isPresented: $showsProjects, arrowEdge: .top) {
            WorkbenchAIProjectsPopover().appLanguage()
        }
    }
}

private struct WorkbenchAIProjectsPopover: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        List {
            AIProjectsSidebarSection(isCompact: false)
        }
        .frame(width: 360, height: 350)
    }
}

struct WorkbenchToolToolbar: ViewModifier {
    let section: ToolSection

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content.toolbar {
            if section != .videoEdit {
                ToolbarItem(placement: .navigation) {
                    Button {
                        MainWindowState.shared.section = .videoEdit
                    } label: {
                        Label("Back to editor", systemImage: "chevron.backward")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .instantHelp("Back to editor")
                }
                .workbenchChrome()
                ToolbarItem(placement: .principal) {
                    Text(LocalizedStringKey(section.title))
                }
                .workbenchChrome()
                ToolbarItemGroup(placement: .primaryAction) {
                    WorkbenchSettingsLink()
                    WorkbenchMoreMenu()
                }
                .workbenchChrome()
            }
        }
    }
}

struct WorkbenchSettingsLink: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        SettingsLink {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .instantHelp("Settings")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("workbench-settings")
    }
}

extension ToolbarContent {
    /// macOS 26 的工具栏不再给每组图标自动垫一块白色胶囊；旧系统照原生样式。
    @ToolbarContentBuilder
    func workbenchChrome() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

import SwiftUI

// MARK: - 剪辑页的单排工具栏
//
// 管什么：左边素材库 / 录屏 / 字幕，中间工程名，右边 AI / 导出 / 设置 / 更多。
// 这里只拿调用方的工程；工程窗口和主窗口复用同一份工具栏，不另找 primary。
// 不管什么：编辑器布局、AI 一轮的生命周期、导出任务本身。

struct VideoEditWorkbenchToolbar: ToolbarContent {
    let project: VideoEditProject
    @Binding var showsLibrary: Bool
    @Binding var showsExport: Bool
    let availableWidth: CGFloat
    @ObservedObject private var round: AIRound
    @ObservedObject private var exporter = VideoEditExporter.shared

    init(project: VideoEditProject, showsLibrary: Binding<Bool>, showsExport: Binding<Bool>, availableWidth: CGFloat) {
        self.project = project
        _showsLibrary = showsLibrary
        _showsExport = showsExport
        self.availableWidth = availableWidth
        _round = ObservedObject(wrappedValue: AISession.shared.round(for: project))
    }

    /// 原生工具栏优先保住右侧操作。长工程名在小窗口先截短，不能把设置 / 更多挤进系统溢出菜单。
    private var projectMenuWidth: CGFloat {
        min(380, max(100, availableWidth - (round.phase == .idle ? 680 : 840)))
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showsLibrary.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .padding(5)
                    .background {
                        if showsLibrary {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.primary.opacity(0.08))
                        }
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .instantHelp("Show or hide the transition, filter and audio library")
            .accessibilityLabel("Library")
            .accessibilityIdentifier("workbench-library")
            RecordScreenButton(project: project)
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
            Button { project.showsSubtitleList.toggle() } label: {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(project.state.isEmpty)
            .instantHelp("Show or hide the subtitle list")
        }
        .workbenchChrome()
        ToolbarItem(placement: .principal) {
            VideoEditProjectMenu(project: project)
                .frame(width: projectMenuWidth)
        }
        .workbenchChrome()
        ToolbarItemGroup(placement: .primaryAction) {
            AIActivityBanner(project: project)
            CloudTasksButton(project: project).equatable()
            if exporter.isExporting && exporter.belongs(to: project) {
                ProgressView(value: exporter.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.primary)
            }
            Button { showsExport = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(project.state.isEmpty || (exporter.isExporting && exporter.belongs(to: project)))
            .instantHelp("Export the timeline or the selected clips")
            .accessibilityIdentifier("workbench-export")
            WorkbenchSettingsLink()
            WorkbenchMoreMenu()
        }
        .workbenchChrome()
    }
}

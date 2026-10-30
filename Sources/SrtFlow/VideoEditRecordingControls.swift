import SwiftUI
import SrtFlowCore

// MARK: - 只由录屏忙闲驱动的两个编辑器控件
// 录屏入口 / 工程帧率菜单各自订阅 coordinator；不用叫醒整个编辑器。
// 状态与设置页仍归 ScreenRecordingCoordinator / ScreenRecordingSheets。
struct RecordScreenButton: View {
    let project: VideoEditProject
    @ObservedObject private var coordinator = ScreenRecordingCoordinator.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if #available(macOS 15.0, *) {
            Button {
                // 设置页只由 coordinator 决定，不另外维护一份本地开关。
                coordinator.begin(for: project)
            } label: {
                Label("Record Screen", systemImage: "record.circle")
            }
            .instantHelp("Record the screen into this project")
            .disabled(coordinator.isBusy)
        }
    }
}

struct ProjectFrameRateMenu: View {
    let project: VideoEditProject
    @ObservedObject private var coordinator = ScreenRecordingCoordinator.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Menu {
            ForEach(ProjectFrameRate.allCases) { rate in
                Button { project.setFrameRate(rate) } label: {
                    if project.state.frameRate == rate {
                        Label(rate.title, systemImage: "checkmark")
                    } else {
                        Text(rate.title)
                    }
                }
            }
        } label: {
            Label(project.state.frameRate.title, systemImage: "speedometer").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coordinator.isBusy)
        .instantHelp("Project frame rate — preview, export and keyframes all follow it")
    }
}

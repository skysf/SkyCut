import SwiftUI

// MARK: - 剪辑页上录屏的几个框：设置页、残缺的结果、崩溃恢复
//
// 管什么：哪个剪辑页弹哪个框、谁去查上次的残留。设置页和残缺的结果弹在**开录的那个工程**的窗口里
// （`ScreenRecordingCoordinator.targetProject`，录完也落进它）；崩溃恢复只在主窗口里查、只在主窗口里弹（恢复出来的东西
// 落进主窗口那个工程）。几个工程窗口挂着同一个协调者，不分的话每个窗口各弹一个（docs/architecture/open-projects.md）。
// 2026-10-17 从 VideoEditView 搬出来（那个文件在行数基线里只许降）。
// 不管什么：框里面（ScreenRecordingSetupView、ScreenRecordingPartialSheet、ScreenRecordingRecoverySheet）、录屏的流程（协调者）。

struct ScreenRecordingSheets: ViewModifier {
    let project: VideoEditProject
    let host: EditorHost
    @ObservedObject private var coordinator = ScreenRecordingCoordinator.shared

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content
            // 录制设置页 = 手动会话 `.configuring` 的投影（AI 起的会话不弹，showsSetupSheet）。会话一旦被撤销
            // （Quit、失败、取消），页自己就关了。
            .sheet(isPresented: Binding(
                get: { coordinator.showsSetupSheet && isTarget },
                set: { if !$0 { coordinator.cancelConfiguring() } }
            )) {
                ScreenRecordingSetupView(project: project).appLanguage()
            }
            // partial 结果：**工程锁还在**，用户必须先处置（计划 §11.4）。
            .sheet(item: Binding(
                get: { isTarget ? coordinator.pendingPartial.map(IdentifiedRecording.init) : nil },
                set: { _ in }
            )) { item in
                ScreenRecordingPartialSheet(result: item.result) { shouldImport in
                    Task { await coordinator.resolvePartial(import: shouldImport) }
                }
                .appLanguage()
            }
            // 崩溃恢复：启动时发现上次的残留。三选一，「保留」绝不删文件。只在主窗口。
            .sheet(item: Binding(
                get: { host == .mainWindow ? coordinator.pendingRecovery : nil },
                set: { _ in }
            )) { recovery in
                ScreenRecordingRecoverySheet(recovery: recovery) { decision in
                    Task { await coordinator.resolveRecovery(decision) }
                }
                .appLanguage()
            }
            .task {
                // 启动恢复：只处理 manifest 点名的精确路径，禁止 glob。只在主窗口查一次（恢复的东西落进主窗口那个工程）。
                guard host == .mainWindow else { return }
                await coordinator.recoverIfNeeded()
            }
    }

    /// 这一次录屏是不是这个工程的（没记过就算主窗口那个的）。
    private var isTarget: Bool {
        (coordinator.targetProject ?? OpenProjects.shared.primary) === project
    }
}

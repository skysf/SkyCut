import AppKit
import Foundation

// MARK: - set_view 那一下把工程的窗口摆到哪
//
// 管什么：看得见 = 把这个工程的窗口摆出来一次（主窗口那个照 AIEditorPresenter 摆：切到剪辑页、窗口放到最前面但不抢键盘；后台工程
// 挂上窗口、放到最前面、不激活 App）；后台 = 工程窗口摘掉、转成没有窗口的后台工程（板 8），主窗口那个不动（那是用户的窗口，只是不再
// 跟着选中 / 挪播放头）。录屏中一律不摆到前面（会被录进去）。之后不再自动摆（docs/plans/2026-10-17-multi-project-ai-editing.md 板 3、F 节）。
// 不管什么：记哪个工程是什么看法（AISession）；窗口怎么挂、怎么摘（OpenProjects）。

@MainActor
enum AIViewPlacement {
    static func place(_ project: VideoEditProject, _ mode: AISession.ViewMode) async throws {
        let recording = ScreenRecordingCoordinator.shared.isBusy
        if project === OpenProjects.shared.primary {
            guard mode == .visible else { return }
            try await AIEditorPresenter.prepareEditor(project: project, bringForward: !recording)
            // 摆过了：之后的调用不再摆（板 3）。
            if !recording, let session = AICallContext.current?.session { _ = AISession.shared.claimFirstShow(of: project, session: session) }
            return
        }
        switch mode {
        case .visible:
            OpenProjects.shared.showWindow(for: project, inFront: !recording)
            guard !recording, let window = OpenProjects.shared.window(of: project) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
        case .background:
            OpenProjects.shared.moveToBackground(project)
        }
    }
}

import SwiftUI

// MARK: - 把变声面板摆出来
//
// 管什么：一个不画东西的小视图，和 UpscalePresenter 一样挂在检查器底下（检查器在剪辑页里一直在），只订阅 `VoiceChangeActivity.panel`：
// 片段右键「换成我的声音…」往那个字段里写，sheet 从这里出。sheet 不继承应用内语言，套一层 `.appLanguage()`
// （checks/presented-views-app-language.sh）。几个工程窗口都挂着它：面板只在那一段所在的工程的窗口里摆。
// `Equatable`（按工程的身份）+ 构造处 `.equatable()`：检查器每重算一次不重算它（预览性能 ratchet）。
// 不管什么：面板里面（VoiceChangePanel / VoiceChangePanelModel）。

struct VoiceChangePresenter: View, Equatable {
    let project: VideoEditProject
    @ObservedObject private var activity = VoiceChangeActivity.shared

    static func == (lhs: VoiceChangePresenter, rhs: VoiceChangePresenter) -> Bool { lhs.project === rhs.project }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: Binding(
                get: { activity.panel.flatMap { project.state.clip(with: $0.id) != nil ? $0 : nil } },
                set: { activity.panel = $0 }
            )) { target in
                if let model = VoiceChangePanelModel(project: project, clipID: target.id) {
                    VoiceChangePanel(model: model, store: .shared).appLanguage()
                } else {
                    // 这一段已经不在了 / 没有声音了：什么都不摆。
                    Color.clear.frame(width: 1, height: 1).onAppear { activity.panel = nil }
                }
            }
    }
}

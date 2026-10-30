import SwiftUI

// MARK: - 顶上那条「AI 正在剪辑」与撤销这一轮
//
// 管什么：AI 在剪**这个工程**的时候显示是谁、给一个停止按钮；这一轮结束或被停下之后，给「撤销这一轮」和关掉。每个剪辑页（主窗口、
// 工程窗口）各一条，只管自己工程的那一轮（`AIRound`，2026-10-17 起，docs/plans/2026-10-17-multi-project-ai-editing.md 板 4）：
// 停止只停这个工程、撤销这一轮只退这个工程。要用户动手的那一句（`AISession.hint`）全 App 一份；要用户点头的事走聊天里的确认码，不在这里问。
// 云端任务集中在工具栏的 CloudTasksButton，不占预览区高度。
// 只订阅 `AISession` 和这个工程的 `AIRound`（两个小对象），不读工程 —— 工程每改一下它都不用重算
// （docs/architecture/preview-perf-ratchet.md 第十三节）。
// 不管什么：这一轮怎么算、停止之后拒绝多久（AIRound）。

struct AIActivityBanner: View {
    @ObservedObject private var session = AISession.shared
    /// 这个工程的这一轮（停止、撤销这一轮都只管它）。
    @ObservedObject private var round: AIRound
    /// 这条横幅在哪个工程的剪辑页上（「撤销这一轮」退的是它）。只拿着、不读它会变的属性，不订阅工程。
    let project: VideoEditProject

    init(project: VideoEditProject) {
        self.project = project
        _round = ObservedObject(wrappedValue: AISession.shared.round(for: project))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        aiBar
    }

    @ViewBuilder
    private var aiBar: some View { statusBar }

    @ViewBuilder
    private var statusBar: some View {
        switch round.phase {
        case .idle:
            EmptyView()
        case .working:
            // 要用户动手的时候先说这件事（比如去点「下载」），不然用户只看到「正在剪辑」、一直干等。
            bar(icon: session.hint == nil ? "sparkles" : "hand.point.up.left",
                message: session.hint ?? String(format: L10n("%@ is editing this project…"), clientName)) {
                Button("Stop") { round.stop() }
                    // 冒烟用辅助功能点按钮（SwiftUI 的按钮没有名字可找；docs/testing/gui-smoke-testing.md 四之八）。
                    .accessibilityIdentifier("ai-banner-stop")
                    .instantHelp("Stop the AI on this project and cancel its exports and subtitle jobs")
            }
        case .finished:
            bar(icon: "checkmark.circle", message: String(format: L10n("%@ made %d changes."), clientName, round.changeCount)) {
                undoRoundButton
                closeButton
            }
        case .stopped:
            bar(icon: "stop.circle", message: L10n("You stopped the AI.")) {
                if round.canUndoRound(project) { undoRoundButton }
                closeButton
            }
        }
    }

    private var clientName: String {
        round.clientName.isEmpty ? L10n("The AI") : round.clientName
    }

    private var undoRoundButton: some View {
        Button("Undo This Round") { round.undoRound(project: project) }
            .disabled(!round.canUndoRound(project))
            .instantHelp("Put the project back to how it was before the AI started this round")
    }

    private var closeButton: some View {
        Button {
            round.dismiss()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .instantHelp("Hide this bar")
    }

    private func bar<Buttons: View>(
        icon: String, message: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                // 平时一行；引导用户动手的那句长，允许折到三行、别被截掉关键的那半句。
                Text(verbatim: message)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                buttons()
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12))
            Divider()
        }
    }
}

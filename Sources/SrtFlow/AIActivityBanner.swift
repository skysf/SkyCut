import SwiftUI

// MARK: - 单排工作台里的 AI 状态与本工程停止按钮
//
// 管什么：正在剪辑时常驻的浅金色状态、详情浮层、停止 / 撤销这一轮。
// 关闭浮层只收起详情，不会隐藏正在剪辑的状态；完成 / 停止后才允许明确隐藏。
// 只订阅 AISession 和本工程的 AIRound；任务百分比只读真实的单个任务，不估算整轮进度。
// 不管什么：一轮的划分和停止纪律（AIRound）、云端任务卡片（CloudTasksButton）。

struct AIActivityBanner: View {
    @ObservedObject private var session = AISession.shared
    @ObservedObject private var round: AIRound
    @State private var showsDetails = false
    let project: VideoEditProject

    init(project: VideoEditProject) {
        self.project = project
        _round = ObservedObject(wrappedValue: AISession.shared.round(for: project))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if round.phase != .idle {
            HStack(spacing: 10) {
                // AIJobs 不可观察；只有运行中的小徽章每秒问一次，不订阅播放器时钟。
                if round.phase == .working {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in statusButton }
                } else {
                    statusButton
                }
                if round.phase == .working {
                    Button { round.stop() } label: {
                        Label("Stop", systemImage: "stop")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("ai-banner-stop")
                    .instantHelp("Stop the AI on this project and cancel its exports and subtitle jobs")
                }
            }
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                details.appLanguage()
            }
        }
    }

    private var statusButton: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: statusIcon)
                Text(LocalizedStringKey(statusTitle))
                if let progress = taskProgress {
                    Text(verbatim: MediaFormatting.percent(progress)).monospacedDigit()
                }
                Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                AIActivityBadgeBackground(isWorking: round.phase == .working)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("ai-activity-status")
        .instantHelp("Show AI activity; any percentage is for the current task")
    }

    private var statusIcon: String {
        switch round.phase {
        case .idle, .working: return "cpu"
        case .finished: return "checkmark.circle"
        case .stopped: return "stop.circle"
        }
    }

    private var statusTitle: String {
        switch round.phase {
        case .idle, .working: return session.hint == nil ? "AI is editing" : "AI needs you"
        case .finished: return "AI finished"
        case .stopped: return "AI stopped"
        }
    }

    /// 多个并行任务没有一个可信的总进度；排队 / 等用户 / 无进度时也不画百分比。
    private var taskProgress: Double? {
        guard round.phase == .working, session.hint == nil else { return nil }
        let jobs = AIJobs.shared.running.filter { $0.stopsWith == round.projectID }
        guard jobs.count == 1, let job = jobs.first,
              AIWorkQueue.shared.position(of: job.id) == nil,
              job.waitingForUser() == nil,
              let progress = job.progress(), progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AI activity", systemImage: "cpu").font(.headline)
                .accessibilityIdentifier("ai-activity-details")
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
            if round.canUndoRound(project) {
                Button("Undo This Round") { round.undoRound(project: project) }
                    .instantHelp("Put the project back to how it was before the AI started this round")
            }
            if round.phase != .working {
                Button("Hide status") {
                    showsDetails = false
                    round.dismiss()
                }
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
    }

    private var message: String {
        let client = round.clientName.isEmpty ? L10n("The AI") : round.clientName
        switch round.phase {
        case .idle: return ""
        case .working: return session.hint ?? String(format: L10n("%@ is editing this project…"), client)
        case .finished: return String(format: L10n("%@ made %d changes."), client, round.changeCount)
        case .stopped: return L10n("You stopped the AI.")
        }
    }
}

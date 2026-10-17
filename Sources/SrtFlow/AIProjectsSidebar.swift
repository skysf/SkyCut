import SwiftUI

// MARK: - 主窗口侧边栏的「AI 在剪的工程」
//
// 管什么：AI 开在主窗口以外的工程（工程窗口里的、后台没有窗口的）在侧边栏各一行：名字（+ 短 id）、在做什么（在剪 / 导出 42% /
// 等你点一下 / 空闲 / 已停止）、停止、打开窗口、关掉。只在有这样的工程时出现（docs/plans/2026-10-17-multi-project-ai-editing.md 板 8、I 节）。
// 后台工程没有窗口、没有横幅，这里是用户唯一能看见它、停下它的地方；AI 忘了 close_project 的话，用户也在这里关掉它。
// 不管什么：工程怎么开关、挂窗口（OpenProjects）；停止的规矩（AIRound）；主窗口里那一个（它有自己的横幅）。
//
// 性能：这一节只读注册表的 `others`（没有 AI 的工程时什么都不画）；每一行自己订阅那个工程的 `AIRound`，任务进度每秒问一次
// （`TimelineView`，只在有行时存在）—— 主窗口的根视图不因此多重算（docs/architecture/preview-perf-ratchet.md 第十三节）。

struct AIProjectsSidebarSection: View, Equatable {
    /// 侧边栏窄到只放得下图标。
    let isCompact: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let listed = OpenProjects.shared.others.filter(Self.isListed)
        if !listed.isEmpty {
            Section {
                ForEach(listed, id: \.shortID) { project in
                    AIProjectSidebarRow(project: project, isCompact: isCompact)
                }
            } header: {
                if !isCompact { Text("AI Projects") }
            }
        }
    }

    /// 列哪些：后台工程（只有 AI 开得出来）、AI 正在剪的工程窗口（用户自己开的工程窗口不列）。
    @MainActor
    private static func isListed(_ project: VideoEditProject) -> Bool {
        let sessions = AIProjectSessions.shared
        if OpenProjects.shared.isHeadless(project) { return true }
        guard let owner = sessions.owner(of: project) else { return false }
        return owner.token == sessions.stamp(project).token
    }
}

/// 一个 AI 工程的那一行。
private struct AIProjectSidebarRow: View {
    let project: VideoEditProject
    let isCompact: Bool
    @ObservedObject private var round: AIRound

    init(project: VideoEditProject, isCompact: Bool) {
        self.project = project
        self.isCompact = isCompact
        _round = ObservedObject(wrappedValue: AISession.shared.round(for: project))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 任务进度不是可观察的：每秒问一次（只在有 AI 工程时这一行才存在）。
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = AIProjectSidebarStatus(project: project, round: round)
            if isCompact {
                Button { OpenProjects.shared.focus(project) } label: {
                    Image(systemName: status.icon)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderless)
                .instantHelp(verbatim: status.summary(of: project))
                .contextMenu { actions(status) }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: status.icon)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(project.projectName) · \(project.shortID)")
                            .lineLimit(1)
                        Text(verbatim: status.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .instantHelp(verbatim: status.detail ?? status.text)
                    Spacer(minLength: 2)
                    iconButtons(status)
                }
                .contextMenu { actions(status) }
            }
        }
    }

    @ViewBuilder
    private func iconButtons(_ status: AIProjectSidebarStatus) -> some View {
        if status.canStop {
            Button { round.stop() } label: { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless)
                .instantHelp("Stop the AI on this project and cancel its exports and subtitle jobs")
        }
        Button { OpenProjects.shared.focus(project) } label: { Image(systemName: "macwindow") }
            .buttonStyle(.borderless)
            .instantHelp("Show this project's window")
        Button { _ = OpenProjects.shared.close(project) } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.borderless)
            .disabled(!status.canClose)
            .instantHelp("Close this project (it is saved first)")
    }

    @ViewBuilder
    private func actions(_ status: AIProjectSidebarStatus) -> some View {
        Button("Stop") { round.stop() }.disabled(!status.canStop)
        Button("Show Window") { OpenProjects.shared.focus(project) }
        Button("Close Project") { _ = OpenProjects.shared.close(project) }.disabled(!status.canClose)
    }
}

/// 一行上写什么、能不能停、能不能关（纯算，一秒算一次）。
@MainActor
private struct AIProjectSidebarStatus {
    let text: String
    let icon: String
    /// 鼠标停上去看的长话（在等用户做的那件事）。
    let detail: String?
    let canStop: Bool
    let canClose: Bool

    /// 侧边栏只剩图标时那个图标的提示：名字、短 id、状态（都是现成的文字，不用翻译）。
    func summary(of project: VideoEditProject) -> String {
        [project.projectName + " (" + project.shortID + ")", text].joined(separator: " · ")
    }

    init(project: VideoEditProject, round: AIRound) {
        let jobs = AIJobs.shared.running.filter { $0.project == project.shortID }
        let waiting = jobs.lazy.compactMap { $0.waitingForUser() }.first
        if round.phase == .stopped {
            (text, icon, detail) = (L10n("Stopped"), "stop.circle", nil)
        } else if let waiting {
            (text, icon, detail) = (L10n("Needs you"), "hand.point.up.left", waiting)
        } else if let job = jobs.first {
            let label = Self.label(job.kind)
            let percent = job.progress().map { " " + MediaFormatting.percent($0) } ?? ""
            (text, icon, detail) = (label + percent, "gearshape.2", nil)
        } else if round.phase == .working {
            (text, icon, detail) = (L10n("Editing…"), "sparkles", nil)
        } else {
            (text, icon, detail) = (L10n("Idle"), OpenProjects.shared.isHeadless(project) ? "moon.zzz" : "macwindow", nil)
        }
        canStop = round.phase == .working || !jobs.isEmpty
        canClose = jobs.isEmpty && !project.isUntitled
    }

    private static func label(_ kind: AIJobs.Kind) -> String {
        switch kind {
        case .export: return L10n("Exporting")
        case .subtitles: return L10n("Making subtitles")
        case .translation: return L10n("Translating")
        case .upscale: return L10n("Upscaling")
        case .generate: return L10n("Generating")
        case .transcript: return L10n("Transcribing")
        case .shots, .compress, .voices, .burnIn, .screenRecording: return L10n("Working")
        }
    }
}

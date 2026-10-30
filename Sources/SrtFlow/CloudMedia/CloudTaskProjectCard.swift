import SwiftUI

// MARK: - 一个工程的生成任务卡片
// 当前工程始终展开，其他工程各自记住展开状态；打开时现核对工程代号，不能指到同一对象换过的新内容。
struct CloudTaskProjectCard: View {
    let group: CloudTaskGroup
    let isCurrent: Bool
    @ObservedObject var activity: CloudTasksActivity
    let onOpen: () -> Void
    @State private var isExpanded = false
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        VStack(alignment: .leading, spacing: 0) {
            if isCurrent {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Current project", systemImage: "viewfinder")
                        .font(.caption).foregroundStyle(Color.accentColor)
                    heading
                }
                .padding(16)
            } else {
                Button { isExpanded.toggle() } label: { heading.padding(14).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cloud-task-project-\(group.owner.shortID)-\(group.id)")
                    .accessibilityValue(isExpanded ? L10n("Expanded") : L10n("Collapsed"))
            }
            if isCurrent || isExpanded {
                if group.summary.count == 0 {
                    Text("No generation tasks in this project").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 20)
                } else {
                    if !isCurrent { openButton.padding(.horizontal, 16).padding(.bottom, 5) }
                    tasks.padding(.horizontal, 16).padding(.bottom, 5)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1).allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if isCurrent {
                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                    .fill(Color.accentColor).frame(height: 3).padding(.horizontal, 1).allowsHitTesting(false)
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            if !isCurrent {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
            }
            Text(verbatim: target?.projectName ?? group.owner.title)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .instantHelp(verbatim: target?.projectName ?? group.owner.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isCurrent {
                if let target, OpenProjects.shared.isHeadless(target) {
                    Text("Background project").font(.caption2).foregroundStyle(.secondary)
                } else if target == nil {
                    Text("Project closed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if group.summary.attentionCount > 0 {
                Label(String(format: L10n("%d need attention"), group.summary.attentionCount), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange).fixedSize()
            }
            Text(verbatim: String(format: L10n("%d tasks"), group.summary.activeCount))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
        }
    }

    private var target: VideoEditProject? { CloudTasksActivity.project(for: group.owner) }

    @ViewBuilder
    private var openButton: some View {
        if let target {
            Button {
                // 动作发生时重新按代号找；浮层打开后关了 / 换了工程，也不能误开另一份内容。
                guard let current = CloudTasksActivity.project(for: group.owner) else { return }
                onOpen()
                OpenProjects.shared.focus(current)
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(OpenProjects.shared.isHeadless(target) ? "Open this project" : "Switch to this project"))
                    Image(systemName: "arrow.up.right").font(.caption2)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityIdentifier("cloud-task-open-\(group.owner.shortID)")
        }
    }

    private var tasks: some View {
        VStack(spacing: 0) {
            ForEach(activity.generations.filter { $0.owner.generation == group.id }) { run in
                CloudGenerationTaskRow(run: run)
            }
            ForEach(activity.upscales.filter { $0.owner.generation == group.id }) { job in
                CloudUpscaleTaskRow(job: job)
            }
        }
    }
}

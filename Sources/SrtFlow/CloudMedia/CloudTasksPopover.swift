import SwiftUI

// MARK: - 轻盈卡片任务浮层：全部 → 当前工程 → 折叠的其他工程
// 数量只算进行中，异常另报；关闭浮层只收界面，不改变任务和积分。
struct CloudTasksPopover: View {
    let project: VideoEditProject
    @ObservedObject var activity: CloudTasksActivity
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    CloudTaskProjectCard(group: currentGroup, isCurrent: true, activity: activity, onOpen: onClose)
                    if !otherGroups.isEmpty {
                        HStack {
                            Text(verbatim: String(format: L10n("Other projects · %d"), otherGroups.count))
                            Spacer()
                            Text(verbatim: String(format: L10n("%d tasks"), otherGroups.reduce(0) { $0 + $1.summary.activeCount }))
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                        ForEach(otherGroups) { group in
                            CloudTaskProjectCard(group: group, isCurrent: false, activity: activity, onOpen: onClose)
                        }
                    }
                }
                .padding(14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 520)
        .frame(maxHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "cloud")
                Text("All generation tasks").font(.headline)
                Text(verbatim: "\(activity.summary.activeCount)")
                    .font(.subheadline).monospacedDigit().padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityIdentifier("cloud-tasks-close").instantHelp("Close this panel")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: statusText).lineLimit(2)
                Spacer(minLength: 5)
                Text(verbatim: estimateText).lineLimit(2).multilineTextAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            if activity.summary.attentionCount > 0 {
                Label(String(format: L10n("%d need attention"), activity.summary.attentionCount), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    private var currentGroup: CloudTaskGroup {
        activity.grouping.group(for: project.documentGeneration)
            ?? CloudTaskGroup(owner: CloudTasksActivity.owner(of: project), summary: CloudTaskSummary(entries: []))
    }

    private var otherGroups: [CloudTaskGroup] {
        activity.grouping.groups.filter { $0.id != project.documentGeneration }
    }

    private var statusText: String {
        let summary = activity.summary
        var parts = [String(format: L10n("%d in queue"), summary.queuedCount),
                     String(format: L10n("%d in progress"), summary.activeCount - summary.queuedCount)]
        if summary.completedCount > 0 { parts.append(String(format: L10n("%d completed"), summary.completedCount)) }
        return parts.joined(separator: " · ")
    }

    private var estimateText: String {
        let summary = activity.summary
        var parts: [String] = []
        if summary.quotedCount > 0 { parts.append(String(format: L10n("Estimated %@ credits"), SkyStudioCredits.text(summary.estimatedCredits))) }
        if summary.hasPendingQuote { parts.append(L10n("Quote pending")) }
        return parts.joined(separator: " · ")
    }
}

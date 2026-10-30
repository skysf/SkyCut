import SwiftUI

// MARK: - 所有工程共用的云端任务入口
// 全局进行中数量和本工程数量分开写；任务与时钟只由小视图订阅，不叫醒编辑器。
struct CloudTasksButton: View, Equatable {
    let project: VideoEditProject
    @Environment(\.locale) private var locale
    @ObservedObject private var activity = CloudTasksActivity.shared
    @State private var isPresented = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.project === rhs.project }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        Group {
            if activity.summary.count > 0 {
                Button { isPresented.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: activity.summary.attentionCount > 0 ? "exclamationmark.icloud" : "cloud")
                        Text(verbatim: String(format: L10n("All generation tasks %d"), activity.summary.activeCount))
                        Divider().frame(height: 12)
                        Text(verbatim: String(format: L10n("This project %d"), currentCount)).font(.caption)
                        Image(systemName: isPresented ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(activity.summary.attentionCount > 0 ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cloud-tasks-button")
                .instantHelp("Show all generation tasks grouped by project")
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    CloudTasksPopover(project: project, activity: activity, onClose: { isPresented = false }).appLanguage()
                }
            }
        }
        .onChange(of: activity.summary.count) { _, count in
            if count == 0 { isPresented = false }
        }
    }

    private var currentCount: Int {
        activity.grouping.group(for: project.documentGeneration)?.summary.activeCount ?? 0
    }
}

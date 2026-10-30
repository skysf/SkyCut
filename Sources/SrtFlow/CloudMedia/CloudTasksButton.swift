import SwiftUI

// MARK: - 右上角生成任务入口与锚定浮层
// 替代占预览高度的多条横幅；关掉浮层只隐藏界面，任务继续。
// 不读工程和播放器；列表 / 单项的状态由各自的小对象驱动。
struct CloudTasksButton: View, Equatable {
    @Environment(\.locale) private var locale
    @ObservedObject private var activity = CloudTasksActivity.shared
    @State private var isPresented = false

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        Group {
            if activity.summary.count > 0 {
                Button { isPresented.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activity.summary.attentionCount > 0 ? "exclamationmark.icloud" : "cloud")
                        Text(verbatim: String(format: L10n("Generation tasks %d"), activity.summary.count))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(activity.summary.attentionCount > 0 ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cloud-tasks-button")
                .instantHelp("Show generation tasks")
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    CloudTasksPopover(activity: activity, onClose: { isPresented = false }).appLanguage()
                }
            }
        }
        .onChange(of: activity.summary.count) { _, count in
            if count == 0 { isPresented = false }
        }
    }
}

struct CloudTasksPopover: View {
    @Environment(\.locale) private var locale
    @ObservedObject var activity: CloudTasksActivity
    let onClose: () -> Void

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Generation tasks").font(.headline)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cloud-tasks-close")
                        .instantHelp("Close this panel")
                }
                Text(verbatim: summaryText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(activity.generations) { run in
                        CloudGenerationTaskRow(run: run)
                        Divider().padding(.horizontal, 18)
                    }
                    ForEach(activity.upscales) { job in
                        CloudUpscaleTaskRow(job: job)
                        Divider().padding(.horizontal, 18)
                    }
                }
            }
            .frame(height: min(400, CGFloat(activity.summary.count) * 80 + CGFloat(activity.summary.attentionCount) * 30))
        }
        .frame(width: 440)
    }

    private var summaryText: String {
        let summary = activity.summary
        var parts: [String] = []
        if summary.queuedCount == summary.activeCount, summary.activeCount > 0 {
            parts.append(String(format: L10n("%d in queue"), summary.queuedCount))
        } else if summary.activeCount > 0 {
            parts.append(String(format: L10n("%d active"), summary.activeCount))
        } else {
            parts.append(String(format: L10n("%d tasks"), summary.count))
        }
        if summary.attentionCount > 0 { parts.append(String(format: L10n("%d need attention"), summary.attentionCount)) }
        if summary.activeCount > 0 {
            if summary.quotedCount > 0 {
                parts.append(String(format: L10n("Estimated %@ credits"), SkyStudioCredits.text(summary.estimatedCredits)))
            }
            if summary.hasPendingQuote { parts.append(L10n("Quote pending")) }
        }
        return parts.joined(separator: " · ")
    }
}

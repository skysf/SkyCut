import SwiftUI

// MARK: - 任务浮层的一行
// 生成 / 配音与 upscale 共用排版，只各自订阅那一项；取消不先从清单拿掉。
// 阶段文字沿用 CloudPhaseText，只有处理中且浮层打开时才订阅一秒钟。
struct CloudGenerationTaskRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var run: SkyStudioMediaStatus

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        CloudTaskRow(title: run.title, model: run.modelTitle, issue: run.issue) {
            if run.issue != nil {
                Text("Needs attention").foregroundStyle(.orange)
            } else if run.waitingForRefund {
                Text("Waiting for refund")
            } else if let progress = run.progress {
                CloudTaskPhaseView(progress: progress)
            } else {
                Text("Preparing")
            }
        } actions: {
            if run.issue != nil {
                Button("Dismiss") { SkyStudioGenerationActivity.shared.dismiss(run) }
                    .instantHelp("Dismiss this task")
            } else {
                if let credits = run.credits {
                    Text(verbatim: String(format: L10n("Estimated %@ credits"), SkyStudioCredits.text(credits)))
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                if CloudTaskSummary.canCancel(run.progress?.phase, waitingForRefund: run.waitingForRefund) {
                    Button("Cancel") { run.cancel() }
                        .instantHelp("Cancel this task")
                }
            }
        }
    }
}

struct CloudUpscaleTaskRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var job: UpscaleJob

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        CloudTaskRow(title: job.title, model: job.request.tier.title, issue: issue) {
            switch job.state {
            case .running(let progress): CloudTaskPhaseView(progress: progress)
            case .done: Text("Completed")
            case .failed: Text("Needs attention").foregroundStyle(.orange)
            case .cancelled: Text("Stopped")
            }
        } actions: {
            switch job.state {
            case .running(let progress):
                Text(verbatim: String(format: L10n("Estimated %@ credits"), SkyStudioCredits.text(job.request.credits)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                if CloudTaskSummary.canCancel(progress.phase) {
                    Button("Cancel") { job.cancel() }
                        .instantHelp("Cancel this task")
                }
            case .done:
                VStack(alignment: .trailing, spacing: 5) {
                    Text(verbatim: String(format: L10n("%@ credits"), SkyStudioCredits.text(job.outcome?.creditsCharged ?? job.request.credits)))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Compare…") { UpscaleActivity.shared.compare = .job(job) }
                            .instantHelp("Compare the original and upscaled video")
                        dismissButton
                    }
                }
            case .failed, .cancelled: dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button("Dismiss") { UpscaleActivity.shared.remove(job) }
            .instantHelp("Dismiss this task")
    }

    private var issue: String? {
        switch job.state {
        case .failed(let message): return message
        case .cancelled(let stop): return stop.localizedNote
        case .running, .done: return nil
        }
    }
}

private struct CloudTaskRow<Detail: View, Actions: View>: View {
    let title: String
    let model: String
    let issue: String?
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .instantHelp(verbatim: title)
                    HStack(spacing: 4) {
                        Text(verbatim: model).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "·")
                        detail().lineLimit(1).fixedSize()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) { actions() }.controlSize(.small)
            }
            if let issue {
                Text(verbatim: issue).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .instantHelp(verbatim: issue)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(minHeight: 80, alignment: .leading)
    }
}

private struct CloudTaskPhaseView: View {
    @Environment(\.locale) private var locale
    let progress: CloudJobProgress

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        if progress.phase.step == .processing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: String(format: L10n("Processing %@"), CloudJobProgress.clock(progress.phaseSeconds(now: context.date))))
            }
        } else {
            Text(verbatim: CloudPhaseText.pill(progress, step: progress.phase, state: .current, now: .now))
        }
    }
}

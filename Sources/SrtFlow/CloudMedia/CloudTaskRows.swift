import SwiftUI

// MARK: - 生成 / 配音与 upscale 的任务行适配
// 一行只订阅自己的任务；浮层暂不放取消，关闭异常提示与比较成片仍保留在详情内。
struct CloudGenerationTaskRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var run: SkyStudioMediaStatus

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        CloudTaskRow(title: run.title, model: run.modelTitle, mediaKind: run.mediaKind, credits: run.credits, issue: run.issue) {
            if run.issue != nil {
                Text("Needs attention").foregroundStyle(.orange)
            } else if run.waitingForRefund {
                Text("Waiting for refund")
            } else if let note = run.stepNote {
                Text(verbatim: note)
            } else if let batches = run.batches, batches.running + batches.waiting > 0 {
                Text(verbatim: Self.batchText(batches))
            } else if let progress = run.progress {
                CloudTaskPhaseView(progress: progress)
            } else {
                Text("Preparing")
            }
        } details: {
            if run.issue == nil {
                if run.waitingForRefund { Text("Waiting for refund") }
                else if let progress = run.progress { CloudPhaseClock(progress: progress, prefix: "") }
            }
            if run.issue != nil {
                Button("Dismiss") { SkyStudioGenerationActivity.shared.dismiss(run) }
                    .instantHelp("Dismiss this task")
            }
        }
    }

    /// 分几批的配旁白：几批好了 / 共几批、几批在跑、几批等空位（SkyCut 声音方案 8.2，不造百分比）。
    private static func batchText(_ board: SkyStudioVoiceBatchBoard) -> String {
        board.waiting == 0
            ? String(format: L10n("%1$d/%2$d batches · %3$d running"), board.done, board.total, board.running)
            : String(format: L10n("%1$d/%2$d batches · %3$d running · %4$d waiting"), board.done, board.total, board.running, board.waiting)
    }
}

struct CloudUpscaleTaskRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var job: UpscaleJob

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        CloudTaskRow(title: job.title, model: job.request.tier.title, mediaKind: .video,
                     credits: job.outcome?.creditsCharged ?? job.request.credits, issue: issue) {
            switch job.state {
            case .running(let progress): CloudTaskPhaseView(progress: progress)
            case .done: Text("Completed")
            case .failed: Text("Needs attention").foregroundStyle(.orange)
            case .cancelled: Text("Stopped")
            }
        } details: {
            switch job.state {
            case .running(let progress): CloudPhaseClock(progress: progress, prefix: "")
            case .done:
                HStack {
                    Button("Compare…") { UpscaleActivity.shared.compare = .job(job) }
                        .instantHelp("Compare the original and upscaled video")
                    dismissButton
                }
            case .failed, .cancelled: dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button("Dismiss") { UpscaleActivity.shared.remove(job) }.instantHelp("Dismiss this task")
    }

    private var issue: String? {
        switch job.state {
        case .failed(let message): return message
        case .cancelled(let stop): return stop.localizedNote
        case .running, .done: return nil
        }
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

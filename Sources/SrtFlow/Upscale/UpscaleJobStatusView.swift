import SwiftUI

// MARK: - 检查器里正在做 / 做完还没处理的 upscale 任务
//
// 管什么：`UpscaleJobStatusView` 只订阅那一个任务，阶段每变一次只有它重算（检查器本体不动）；阶段文字（上传 / 下载的百分比、
// 处理了多久、这一档通常几分钟）和状态行同一份（FalPhaseText）。
// 检查器里「Upscale」那一节本身在 VideoEditInspector+Upscale.swift（是检查器的一段 body，不是单独的视图：
// 预览性能 ratchet 数的是 body 次数，选一段多一个视图就是多一次）。
// 不管什么：面板和对比窗口怎么摆（UpscalePresenter）、换源（VideoEditProject+Upscale）。

/// 一个正在做 / 做完还没处理的任务在检查器里的样子（只订阅这一个任务）。
struct UpscaleJobStatusView: View {
    @ObservedObject var job: UpscaleJob
    let activity: UpscaleActivity

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let tier = job.request.tier
        VStack(alignment: .leading, spacing: 6) {
            switch job.state {
            case .running(let progress):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    // 「Topaz Starlight · processing 1:12 · usually about 3 min」，每秒走一下（FalPhaseClock）。
                    FalPhaseClock(progress: progress, prefix: "\(tier.title) · ")
                        .font(.caption)
                }
                if job.keyPrompt {
                    Text("macOS is about to ask whether SkyCut may use your Sky Studio key. Click Always Allow.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(String(format: L10n("%@ s · %@ credits"), String(format: "%.1f", job.request.range.duration), SkyStudioCredits.text(job.request.credits)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { activity.remove(job) }.controlSize(.small)
                }
                Text("You can keep editing. The compare window opens when it is done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .done:
                Text("Upscaled. Compare it, then decide.").font(.caption)
                HStack(spacing: 8) {
                    Button("Compare…") { activity.compare = .job(job) }
                    Button("Discard") { activity.remove(job) }
                        .instantHelp("Forget this result; the file stays on disk")
                }
                .controlSize(.small)
            case .failed(let message):
                Text(String(format: L10n("Upscale failed: %@"), message)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { activity.remove(job) }.controlSize(.small)
            case .cancelled(let stop):
                Text(stop.localizedNote ?? L10n("Upscale cancelled.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { activity.remove(job) }.controlSize(.small)
            }
        }
    }
}

extension SkyStudioJobError.Stop {
    /// 停下来时界面上那一句（本地化）：没花钱的就是「已取消」（nil），花了的照实说。
    var localizedNote: String? {
        switch self {
        case .nothingCharged: return nil
        case .alreadyStarted:
            return L10n("Sky Studio had already started it, so it could not be cancelled: the credits are spent and the result will appear in your Sky Studio library.")
        case .unknown:
            return L10n("SkyCut could not reach Sky Studio to cancel it; it may still finish and appear in your Sky Studio library.")
        }
    }
}

import SwiftUI

// MARK: - 云端任务的阶段文字与检查器计时
// 检查器和任务浮层共用一份文字规则；不持有任务清单、不占预览布局。

/// 检查器那一节用：一句阶段文字，每秒走一下。
struct CloudPhaseClock: View {
    let progress: CloudJobProgress
    let prefix: String

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: prefix + CloudPhaseText.inspector(progress, now: context.date))
        }
    }
}

/// 阶段怎么写成字（本地化）：检查器里小写的一句、状态行上的小标。
enum CloudPhaseText {
    enum PillState: Equatable { case done, current, upcoming }

    /// 检查器：「uploading 35%」「in queue (3)」「processing 1:12 · usually about 2 min」「downloading 80%」。
    static func inspector(_ progress: CloudJobProgress, now: Date) -> String {
        switch progress.phase {
        case .preparing: return L10n("preparing")
        case .uploading(let fraction): return L10n("uploading") + percentSuffix(fraction)
        case .queued(let position): return position.map { String(format: L10n("in queue (%d)"), $0) } ?? L10n("in queue")
        case .processing: return L10n("processing") + " " + CloudJobProgress.clock(progress.phaseSeconds(now: now)) + usuallySuffix(progress)
        case .downloading(let fraction): return L10n("downloading") + percentSuffix(fraction)
        case .finishing: return L10n("finishing")
        }
    }

    /// 状态行上的小标：当前的那个带百分比 / 已用时间，别的只有名字。
    static func pill(_ progress: CloudJobProgress, step: CloudJobPhase, state: PillState, now: Date) -> String {
        guard state == .current else { return title(step) }
        switch progress.phase {
        case .preparing: return L10n("Preparing")
        case .uploading(let fraction): return fraction.map { String(format: L10n("Uploading %d%%"), Int(($0 * 100).rounded())) } ?? L10n("Uploading")
        case .queued(let position): return position.map { String(format: L10n("In queue (%d)"), $0) } ?? L10n("In queue")
        case .processing:
            return String(format: L10n("Processing %@"), CloudJobProgress.clock(progress.phaseSeconds(now: now))) + usuallySuffix(progress)
        case .downloading(let fraction): return fraction.map { String(format: L10n("Downloading %d%%"), Int(($0 * 100).rounded())) } ?? L10n("Downloading")
        case .finishing: return L10n("Finishing")
        }
    }

    private static func title(_ step: CloudJobPhase) -> String {
        switch step {
        case .preparing: return L10n("Preparing")
        case .uploading: return L10n("Uploading")
        case .queued: return L10n("In queue")
        case .processing: return L10n("Processing")
        case .downloading: return L10n("Downloading")
        case .finishing: return L10n("Finishing")
        }
    }

    private static func percentSuffix(_ fraction: Double?) -> String {
        fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    /// 「 · usually about 2 min」：知道这一档通常要多久才加。
    private static func usuallySuffix(_ progress: CloudJobProgress) -> String {
        progress.typicalSeconds.map { " · " + String(format: L10n("usually about %d min"), CloudJobProgress.minutes($0)) } ?? ""
    }
}

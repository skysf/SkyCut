import Foundation

// MARK: - 一件云端生成的界面状态（素材生成 / 配音共用）
// 管什么：浮层这一行的名字、模型、报价、阶段、取消与待处理问题；任务本身与工程不发界面时钟。
// 不管什么：生成怎么跑、钱怎么算、任务的最终结果（AIJobs）。

@MainActor
final class SkyStudioMediaStatus: ObservableObject, Identifiable {
    let id = UUID()
    let kindLabel: String
    let title: String
    let uploads: Bool
    let owner: CloudTaskOwner
    let mediaKind: CloudTaskMediaKind
    /// 登记到活动清单之前绑定；这是 get_job 接受的任务号，不是界面 UUID。
    var aiJobID: String?
    @Published var modelTitle: String
    @Published var credits: Double?
    @Published private(set) var progress: CloudJobProgress?
    @Published var waitingForRefund = false
    @Published var issue: String?
    /// 分几批交的配旁白：几批好了 / 共几批、几批在跑、几批等空位（状态行照它写，不造百分比）；一批的、别的生成是 nil。
    @Published private(set) var batches: SkyStudioVoiceBatchBoard?
    var onCancel: () -> Void = {}

    init(kindLabel: String, modelTitle: String, credits: Double?, uploads: Bool, title: String? = nil,
         owner: CloudTaskOwner, mediaKind: CloudTaskMediaKind) {
        self.kindLabel = kindLabel
        self.title = title ?? kindLabel
        self.modelTitle = modelTitle
        self.credits = credits
        self.uploads = uploads
        self.owner = owner
        self.mediaKind = mediaKind
    }

    func advance(to phase: CloudJobPhase, typicalSeconds: Double?) {
        let next = (progress ?? CloudJobProgress(phase: phase, typicalSeconds: typicalSeconds)).advanced(to: phase)
        if progress != next { progress = next }
    }

    /// 几批同时跑的配旁白：阶段照几批合出来的那一个，状态行另写几批各在哪（只有一批时照一批的样子显示）。
    func show(_ board: SkyStudioVoiceBatchBoard) {
        advance(to: board.phase, typicalSeconds: nil)
        let next = board.total > 1 ? board : nil
        if batches != next { batches = next }
    }

    func cancel() { onCancel() }
}

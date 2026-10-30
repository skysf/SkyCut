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

    /// 一批配完开始下一批时，阶段时钟重新起步；不会把上一批的下载当成新一批的进度。
    func reset(typicalSeconds: Double?) {
        progress = CloudJobProgress(phase: .preparing, typicalSeconds: typicalSeconds)
    }

    func cancel() { onCancel() }
}

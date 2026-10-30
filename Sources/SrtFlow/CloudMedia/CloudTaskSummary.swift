import Foundation

// MARK: - 任务入口的计数与预计积分（纯值）
// 只汇总正在跑的报价；失败 / 已完成不再算预计消费。未知报价不能当作零。
// 不管任务执行、退款和界面时钟；取消规则供生成与 upscale 共用。
struct CloudTaskSummary: Equatable {
    struct Entry {
        var id: UUID
        var active: Bool
        var queued: Bool
        var attention: Bool
        var credits: Double?
    }

    var ids: [UUID]
    var activeCount: Int
    var queuedCount: Int
    var attentionCount: Int
    var estimatedCredits: Double
    var quotedCount: Int
    var hasPendingQuote: Bool
    var count: Int { ids.count }

    init(entries: [Entry]) {
        ids = entries.map(\.id)
        let active = entries.filter(\.active)
        activeCount = active.count
        queuedCount = active.filter(\.queued).count
        attentionCount = entries.filter(\.attention).count
        let quotes = active.compactMap(\.credits).filter { $0.isFinite && $0 >= 0 }
        estimatedCredits = quotes.reduce(0, +)
        quotedCount = quotes.count
        hasPendingQuote = quotes.count != active.count
    }

    static func canCancel(_ phase: CloudJobPhase?, waitingForRefund: Bool = false) -> Bool {
        if waitingForRefund { return true }
        switch phase ?? .preparing {
        case .preparing, .uploading, .queued: return true
        case .processing, .downloading, .finishing: return false
        }
    }
}

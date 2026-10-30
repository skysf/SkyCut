import Foundation

// 预计消费只含进行中的报价；取消只出现在真正还能取消的阶段。
func runTaskSummaryChecks() {
    let ids = (0..<4).map { _ in UUID() }
    let rows = zip(ids, [240.0, 112, 112, 176]).map {
        CloudTaskSummary.Entry(id: $0.0, active: true, queued: true, attention: false, credits: $0.1)
    }
    let queued = CloudTaskSummary(entries: rows)
    checkEqual(queued.count, 4, "four queued tasks occupy one toolbar entry")
    checkEqual(queued.queuedCount, 4, "all queued tasks are counted")
    checkEqual(queued.estimatedCredits, 640, "the four estimates total 640 credits")
    check(!queued.hasPendingQuote, "all four quotes are known")
    var changed = rows
    changed[0].active = false
    changed[0].attention = true
    let failed = CloudTaskSummary(entries: changed)
    checkEqual(failed.count, 4, "an issue remains visible until dismissed")
    checkEqual(failed.activeCount, 3, "an issue is not an active charge")
    checkEqual(failed.queuedCount, 3, "an issue is not queued")
    checkEqual(failed.estimatedCredits, 400, "an issue's old estimate is excluded")
    checkEqual(failed.attentionCount, 1, "the badge exposes the retained issue")
    changed[1].credits = nil
    changed[2].credits = .infinity
    let pending = CloudTaskSummary(entries: changed)
    check(pending.hasPendingQuote, "unknown and invalid quotes cannot silently count as zero")
    checkEqual(pending.quotedCount, 1, "only a finite active quote can be displayed")
    checkEqual(pending.estimatedCredits, 176, "known estimates remain available alongside pending quotes")
    let empty = CloudTaskSummary(entries: [])
    checkEqual(empty.count, 0, "no retained task means no toolbar badge")
    check(!empty.hasPendingQuote, "empty is not a pending quote")
    for phase in [CloudJobPhase.preparing, .uploading(fraction: 0.2), .queued(position: 3)] {
        check(CloudTaskSummary.canCancel(phase), "a preparing/uploading/queued task may cancel")
    }
    for phase in [CloudJobPhase.processing, .downloading(fraction: nil), .finishing] {
        check(!CloudTaskSummary.canCancel(phase), "an accepted/finished task must not promise cancellation")
    }
    check(CloudTaskSummary.canCancel(.processing, waitingForRefund: true), "refund waiting can stop without creating a replacement")
}

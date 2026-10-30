import Foundation
import SrtFlowMCPKit

// 按工程识别任务：当前工程只取自己那一次打开的任务，MCP 和卡片共用同一份分组 / 报价规则。
func runTaskGroupingChecks() {
    let owners = (1...10).map { CloudTaskOwner(generation: $0, token: "run:\($0)", shortID: "p\($0)", title: "Project \($0)") }
    let entries = owners.flatMap { owner in
        (0..<2).map { index in
            CloudTaskGrouping.Entry(owner: owner, task: .init(id: UUID(), active: true, queued: index == 1, attention: false, credits: 80))
        }
    }
    let grouped = CloudTaskGrouping(entries: entries)
    checkEqual(grouped.summary.activeCount, 20, "ten projects with two tasks have twenty active tasks globally")
    checkEqual(grouped.groups.count, 10, "every project has its own group")
    checkEqual(grouped.group(for: 6)?.summary.activeCount, 2, "the current project sees only its two tasks")
    checkEqual(grouped.group(for: 6)?.summary.estimatedCredits, 160, "per-project quotes exclude other projects")
    check(grouped.group(for: 11) == nil, "switching document content does not relabel old tasks as the new project")
    checkEqual(grouped.groups.map(\.id), Array(1...10), "progress updates do not reorder groups")
    let duplicateName = CloudTaskOwner(generation: 12, token: "run:12", shortID: "p1", title: "Project 1")
    let extra = CloudTaskGrouping.Entry(owner: duplicateName, task: .init(id: UUID(), active: true, queued: true, attention: false, credits: nil))
    let reopened = CloudTaskGrouping(entries: entries + [extra])
    checkEqual(reopened.group(for: 1)?.summary.activeCount, 2, "the old document keeps its own tasks")
    checkEqual(reopened.group(for: 12)?.summary.activeCount, 1, "same short id and title do not merge distinct document generations")
    check(reopened.group(for: 12)?.summary.hasPendingQuote == true, "an unquoted task is explicitly pending")

    var changed = entries
    changed[0] = .init(owner: owners[0], task: .init(id: entries[0].task.id, active: false, queued: true, attention: true, credits: 80))
    let failed = CloudTaskGrouping(entries: changed)
    checkEqual(failed.summary.activeCount, 19, "a failed task no longer inflates the active total")
    checkEqual(failed.group(for: 1)?.summary.attentionCount, 1, "a collapsed project's issue remains countable")
    checkEqual(failed.summary.estimatedCredits, 1520, "a failed task's old quote is excluded")
    checkEqual(Set(CloudTaskMediaKind.allCases.map(\.systemImage)).count, 3, "video, audio, image use different icon shapes")

    checkTaskReport(owner: owners[0], other: owners[1])
}

private func checkTaskReport(owner: CloudTaskOwner, other: CloudTaskOwner) {
    let start = Date(timeIntervalSince1970: 1000)
    let ids = (0..<3).map { _ in UUID() }
    let entries: [CloudTaskGrouping.Entry] = [
        .init(owner: owner, task: .init(id: ids[0], active: true, queued: true, attention: false, credits: 80)),
        .init(owner: owner, task: .init(id: ids[1], active: true, queued: false, attention: false, credits: nil)),
        .init(owner: other, task: .init(id: ids[2], active: false, queued: false, attention: true, credits: 120))
    ]
    let tasks: [CloudTaskReport.Task] = [
        .init(id: ids[0], owner: owner, mediaKind: .video, title: "Video", model: "Video model", credits: 80, status: "running",
              progress: .init(phase: .queued(position: 2), phaseStarted: start), waitingForRefund: false, issue: nil, jobID: "generate-1", serverJobID: "server-1"),
        .init(id: ids[1], owner: owner, mediaKind: .audio, title: "Voice", model: "Voice model", credits: nil, status: "running",
              progress: .init(phase: .processing, phaseStarted: start), waitingForRefund: false, issue: nil, jobID: "voiceover-2", serverJobID: nil),
        .init(id: ids[2], owner: other, mediaKind: .image, title: "Image", model: "Image model", credits: 120, status: "needs_attention",
              progress: nil, waitingForRefund: false, issue: "Refund unknown", jobID: "generate-3", serverJobID: "server-3")
    ]
    let report = CloudTaskReport(grouping: .init(entries: entries), tasks: tasks,
        projects: [.init(generation: owner.generation, title: "Renamed project", shownIn: "background (no window)")], now: start.addingTimeInterval(12))
    let root = report.json().objectValue ?? [:]
    let groups = root["projects"]?.arrayValue ?? []
    let first = groups.first?.objectValue ?? [:]
    let records = first["tasks"]?.arrayValue ?? []
    checkEqual(first["project_name"], .string("Renamed project"), "open projects report their current name")
    checkEqual(first["shown_in"], .string("background (no window)"), "MCP reports background location without opening a window")
    checkEqual(first["project_token"], .string(owner.token), "MCP preserves the original document token")
    checkEqual(records.count, 2, "project details contain only that project's tasks")
    let queued = records.first?.objectValue ?? [:]
    checkEqual(queued["media_type"], .string("video"), "MCP reports the actual media type")
    checkEqual(queued["job_id"], .string("generate-1"), "get_job receives its real task id, not the UI UUID")
    checkEqual(queued["skystudio_job_id"], .string("server-1"), "server task id stays available for progress enquiries")
    checkEqual(queued["queue_position"], .number(2), "queue position comes from the shared phase model")
    let processing = records.last?.objectValue ?? [:]
    checkEqual(processing["phase_seconds"], .number(12), "elapsed processing uses the same stage clock")
    check(processing["transfer_percent"] == nil, "processing never invents a percentage")
    check(processing["quoted_credits"] == nil, "unknown quotes are not reported as zero")
    let closed = groups.last?.objectValue ?? [:]
    checkEqual(closed["project_open"], .bool(false), "closed projects retain status without being made openable")
    checkEqual(closed["project_name"], .string(other.title), "closed projects retain their original name")
    checkEqual(closed["tasks"]?.arrayValue?.first?.objectValue?["issue"], .string("Refund unknown"), "retained issues are readable through MCP")
    checkEqual(report.summary(for: 999).objectValue?["active_count"], .number(0), "a new empty project has no inherited task count")
    checkEqual(report.taskIDs(for: owner.generation).arrayValue?.count, 2, "open project task ids match the detailed report")
    let refund = CloudTaskReport.Task(id: ids[0], owner: owner, mediaKind: .video, title: "Refund", model: "Model", credits: 80,
        status: "running", progress: .init(phase: .processing, phaseStarted: start), waitingForRefund: true,
        issue: nil, jobID: "generate-1", serverJobID: "server-1")
    let waiting = CloudTaskReport(grouping: .init(entries: [entries[0]]), tasks: [refund], projects: [], now: start.addingTimeInterval(50))
    let waitTask = waiting.json().objectValue?["projects"]?.arrayValue?.first?.objectValue?["tasks"]?.arrayValue?.first?.objectValue ?? [:]
    checkEqual(waitTask["phase"], .string("waiting_for_refund"), "refund waiting is distinct from generation processing")
    check(waitTask["phase_seconds"] == nil, "refund waiting does not keep presenting the old generation clock")
}

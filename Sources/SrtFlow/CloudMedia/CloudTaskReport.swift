import Foundation
import SrtFlowMCPKit

// MARK: - MCP 只读的工程生成任务快照（纯值）
// 和卡片共用分组 / 计数；任务号、素材类型、阶段和异常供 AI 转述，不开窗、不提交或取消任务。
struct CloudTaskReport {
    struct Task {
        let id: UUID
        let owner: CloudTaskOwner
        let mediaKind: CloudTaskMediaKind
        let title: String
        let model: String
        let credits: Double?
        let status: String
        let progress: CloudJobProgress?
        let waitingForRefund: Bool
        let issue: String?
        let jobID: String?
        let serverJobID: String?
    }

    struct Project {
        let generation: Int
        let title: String
        let shownIn: String
    }

    let grouping: CloudTaskGrouping
    let tasks: [Task]
    let projects: [Project]
    var now = Date()

    func json() -> JSONValue {
        .object([
            "summary": Self.summaryJSON(grouping.summary),
            "projects": .array(grouping.groups.map { group in
                let project = projects.first { $0.generation == group.id }
                return .object([
                    "project": .string(group.owner.shortID), "project_token": .string(group.owner.token),
                    "project_name": .string(project?.title ?? group.owner.title),
                    "project_open": .bool(project != nil), "shown_in": .string(project?.shownIn ?? "closed"),
                    "summary": Self.summaryJSON(group.summary),
                    "tasks": .array(tasks.filter { $0.owner.generation == group.id }.map(taskJSON))
                ])
            })
        ])
    }

    func summary(for generation: Int) -> JSONValue {
        Self.summaryJSON(grouping.group(for: generation)?.summary ?? CloudTaskSummary(entries: []))
    }

    func taskIDs(for generation: Int) -> JSONValue {
        .array(tasks.filter { $0.owner.generation == generation }.map { .string($0.id.uuidString) })
    }

    static func summaryJSON(_ summary: CloudTaskSummary) -> JSONValue {
        var result: [String: JSONValue] = [
            "active_count": .number(Double(summary.activeCount)), "queued_count": .number(Double(summary.queuedCount)),
            "in_progress_count": .number(Double(summary.activeCount - summary.queuedCount)),
            "needs_attention_count": .number(Double(summary.attentionCount)), "completed_count": .number(Double(summary.completedCount)),
            "quote_pending": .bool(summary.hasPendingQuote)
        ]
        if summary.quotedCount > 0 { result["estimated_credits"] = .number(summary.estimatedCredits) }
        return .object(result)
    }

    private func taskJSON(_ task: Task) -> JSONValue {
        var result = task.progress?.json(now: now) ?? [:]
        result["task_id"] = .string(task.id.uuidString)
        result["media_type"] = .string(task.mediaKind.rawValue)
        result["name"] = .string(task.title)
        result["model"] = .string(task.model)
        result["status"] = .string(task.status)
        if task.status == "running" {
            if task.waitingForRefund {
                result["phase"] = "waiting_for_refund"
                for key in ["phase_seconds", "queue_position", "transfer_percent", "typical_seconds"] { result.removeValue(forKey: key) }
            }
            else if result["phase"] == nil { result["phase"] = "preparing" }
        }
        if let credits = task.credits, credits.isFinite, credits >= 0 { result["quoted_credits"] = .number(credits) }
        if let issue = task.issue { result["issue"] = .string(issue) }
        if let job = task.jobID { result["job_id"] = .string(job) }
        if let server = task.serverJobID { result["skystudio_job_id"] = .string(server) }
        return .object(result)
    }
}

import Foundation
import SrtFlowMCPKit

// MARK: - 从现有活动对象读一份 MCP 快照
// 只读当前状态；媒体图标、归属和报价与浮层同源。手动 upscale 没有 get_job 任务号时只报界面 task_id。
@MainActor
enum CloudTaskStatusSnapshot {
    static func read() -> CloudTaskReport {
        let activity = CloudTasksActivity.shared
        let generations = activity.generations.map { run in
            CloudTaskReport.Task(id: run.id, owner: run.owner, mediaKind: run.mediaKind, title: run.title,
                model: run.modelTitle, credits: run.credits, status: run.issue == nil ? "running" : "needs_attention",
                progress: run.issue == nil ? run.progress : nil, waitingForRefund: run.waitingForRefund, issue: run.issue, jobID: run.aiJobID,
                serverJobID: serverJobID(for: run.aiJobID))
        }
        let upscales = activity.upscales.map { job -> CloudTaskReport.Task in
            let status: String
            let progress: CloudJobProgress?
            let issue: String?
            switch job.state {
            case .running(let value): status = "running"; progress = value; issue = nil
            case .done: status = "done"; progress = nil; issue = nil
            case .failed(let message): status = "failed"; progress = nil; issue = message
            case .cancelled(let stop): status = "cancelled"; progress = nil; issue = stop.localizedNote
            }
            return .init(id: job.id, owner: job.owner, mediaKind: .video, title: job.title, model: job.request.tier.title,
                credits: job.request.credits, status: status, progress: progress, waitingForRefund: false,
                issue: issue, jobID: job.aiJobID, serverJobID: job.skyStudioJobID)
        }
        let projects = OpenProjects.shared.all.map {
            CloudTaskReport.Project(generation: $0.documentGeneration, title: $0.projectName, shownIn: AIProjectStatus.shownIn($0))
        }
        return CloudTaskReport(grouping: activity.snapshot(), tasks: generations + upscales, projects: projects)
    }

    private static func serverJobID(for id: String?) -> String? {
        guard let id, let job = AIJobs.shared.job(id) else { return nil }
        // 任务结束后 run 已释放，liveDetail 的弱引用也空了；失败提示必须从 AIJobs 留下的终态取任务号。
        return AIJobs.shared.json(job).objectValue?["skystudio_job_id"]?.stringValue
    }
}

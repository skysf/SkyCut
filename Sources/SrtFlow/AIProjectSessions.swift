import Foundation
import SrtFlowMCPKit

// MARK: - App 这一头：哪个 AI 会话在剪哪几个工程
//
// 管什么：把开着的工程（OpenProjects）摆成纯值、按 `AIProjectTargeting` 的规矩判一个调用落在哪、记下归属
// （`AIProjectOwnership`：打开 / 新建 / 收下 / 接手 / 关掉）、给工程盖「身份章」（`ProjectStamp`，回给小程序记着）。
// 不管什么：规矩本身（AIProjectTargeting，纯值）；排队和执行（AIToolRouter）；开 / 关工程（AIProjectOpenTools）。
// docs/plans/2026-10-17-multi-project-ai-editing.md 板 1、7，B 节；长期约束 docs/architecture/ai-control-mcp.md 第四节第 46 条。

@MainActor
final class AIProjectSessions {
    static let shared = AIProjectSessions()
    /// 老小程序不带会话号：当成同一个会话（它们本来就只认「一个会话一个工程」）。
    static let anonymous = "anonymous"

    private(set) var ownership = AIProjectOwnership()

    private init() {}

    /// 每个调用进来都记一笔：别的会话据此判断这个会话还在不在剪（安静 5 分钟以上算放手了）。
    func noteCall(session: String) { ownership.noteCall(session: session, at: Date()) }

    /// 工程此刻的身份章（token = 这一次运行 + 这一次打开的代号，外加短 id、路径、名字）。
    func stamp(_ project: VideoEditProject) -> MCPBridge.ProjectStamp {
        MCPBridge.ProjectStamp(
            token: AIProjectBinding.token(generation: project.documentGeneration),
            path: project.documentURL?.path, name: project.projectName, id: project.shortID
        )
    }

    /// 开着的工程（纯值）。
    var openProjects: [AIOpenProject] {
        let projects = OpenProjects.shared
        return projects.all.map { AIOpenProject(id: $0.shortID, stamp: stamp($0), isPrimary: $0 === projects.primary) }
    }

    /// 一个碰工程的调用落在哪个工程上；不能落就是回给 AI 的那句话。收下 / 接手的当场记成这个会话的。
    func target(
        explicitID: String?, remembered: MCPBridge.ProjectStamp?, session: String, client: String
    ) -> Result<VideoEditProject, AIToolError> {
        let decision = AIProjectTargeting.decide(
            explicitID: explicitID, remembered: remembered, session: session,
            open: openProjects, ownership: ownership, now: Date(), run: AIProjectBinding.runID
        )
        switch decision {
        case .refuse(let text):
            return .failure(AIToolError(text))
        case .use(let id), .adopt(let id):
            guard let project = OpenProjects.shared.project(shortID: id) else {
                return .failure(AIToolError("Not done: project \(id) is not open in SkyCut. Nothing was changed."))
            }
            if case .adopt = decision { own(project, session: session, client: client) }
            return .success(project)
        }
    }

    /// 这个会话打开 / 新建 / 收下了它：归它，成为它最后打开的那个；看得见还是后台照这个会话的默认（方案 F 节）。
    func own(_ project: VideoEditProject, session: String, client: String) {
        ownership.own(project.shortID, session: session, client: client, token: stamp(project).token)
        AISession.shared.setViewMode(AISession.shared.defaultViewMode(session: session), for: project)
    }

    /// 关掉了（close_project、用户关了它的窗口）：谁都不归。
    func release(_ project: VideoEditProject) { ownership.release(project.shortID) }

    /// 归谁（没人剪的是 nil）。
    func owner(of project: VideoEditProject) -> AIProjectOwnership.Owner? { ownership.owners[project.shortID] }

    /// 这个会话的工程（按打开的先后）。
    func projects(of session: String) -> [VideoEditProject] {
        (ownership.opened[session] ?? []).compactMap { OpenProjects.shared.project(shortID: $0) }
    }

    /// 主窗口里空着：没存过、没内容、没改动，也没有别的会话正在用它 —— AI 看得见地开 / 建工程时装进来（一个会话剪一条时和以前
    /// 一模一样，方案 A.4）。这个会话自己收下的空 Untitled（先读了一下时间线）照样算空着；别的会话收下了、5 分钟没动静也算放手了。
    func primaryIsFree(for session: String) -> Bool {
        let primary = OpenProjects.shared.primary
        guard primary.isUntitled, primary.state.isEmpty, !primary.hasUnsavedChanges else { return false }
        // 内容换过的旧归属不算；自己的不挡。
        guard let owner = owner(of: primary), owner.token == stamp(primary).token, owner.session != session else { return true }
        return !ownership.isActive(owner.session, at: Date())
    }
}

/// get_status 里的 `projects`：开着的每一个工程 —— 短 id、名字、路径、是不是你的（别人的写是哪个客户端在剪）、在哪个窗口、
/// 有没有没存的改动、在跑的任务。AI 据此知道哪些能用、哪些该关（方案板 2、7）。
@MainActor
enum AIProjectStatus {
    /// 放在哪：主窗口 / 自己的窗口 / 后台（没有窗口：用户在主窗口的「AI 在剪的工程」里能打开）。
    static func shownIn(_ project: VideoEditProject) -> String {
        if project === OpenProjects.shared.primary { return "main window" }
        return OpenProjects.shared.isHeadless(project) ? "background (no window)" : "own window"
    }

    static func openProjects(session: String?, cloudTasks: CloudTaskReport) -> JSONValue {
        let sessions = AIProjectSessions.shared
        let running = AIJobs.shared.running
        return .array(OpenProjects.shared.all.map { project in
            var item: [String: JSONValue] = [
                "id": .string(project.shortID),
                "name": .string(project.projectName),
                "shown_in": .string(shownIn(project)),
                "unsaved_changes": .bool(project.hasUnsavedChanges)
            ]
            item["cloud_task_summary"] = cloudTasks.summary(for: project.documentGeneration)
            item["cloud_task_ids"] = cloudTasks.taskIDs(for: project.documentGeneration)
            if let path = project.documentURL?.path { item["path"] = .string(path) }
            if let owner = sessions.owner(of: project), owner.token == sessions.stamp(project).token {
                item["yours"] = .bool(owner.session == session)
                if owner.session != session { item["edited_by"] = .string(owner.client) }
            } else {
                item["yours"] = false
            }
            item["view"] = .string(AISession.shared.viewMode(for: project).rawValue)
            if AISession.shared.round(for: project).phase == .stopped { item["stopped_by_user"] = true }
            let jobs = running.filter { $0.project == project.shortID }.map { JSONValue.string($0.id) }
            if !jobs.isEmpty { item["running_jobs"] = .array(jobs) }
            return .object(item)
        })
    }
}

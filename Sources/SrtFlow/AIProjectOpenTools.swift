import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：打开 / 新建 / 关掉工程（2026-10-17 起几个工程可以同时开着）
//
// 管什么：open_project / new_project / close_project 在 App 里怎么做 —— 开在哪（主窗口空着就装进去，否则自己的窗口；
// 后台模式放到别的窗口后面）、同一个文件只开一份、别的会话还在剪的不给开、到顶（8 个）就拒、开 / 建完归这个会话、
// 关之前先落盘、有任务在跑就不关。回的结果带工程的短 id（`project`），身份章（`AIToolResult.stamp`）交给路由回给小程序记着。
// 不管什么：落在哪 / 归谁的规矩（AIProjectTargeting）、注册表（OpenProjects）、排队（AIToolRouter）。
// 方案：docs/plans/2026-10-17-multi-project-ai-editing.md 板 1、2、7，A 节；长期约束：docs/architecture/ai-control-mcp.md 第四节第 46 条。
//
// **不许弹模态框**（ai-control-mcp.md 第四节第 5 条）：只在主窗口空着时才往里装（没有要存的），关主窗口那个之前先替它存好。

@MainActor
enum AIProjectOpenTools {
    private static var sessions: AIProjectSessions { .shared }
    private static var session: String { AICallContext.current?.session ?? AIProjectSessions.anonymous }
    private static var client: String { AICallContext.current?.client ?? "AI" }

    static func openProject(_ args: AIToolArguments, inFront: Bool) async throws -> AIToolResult {
        let url = AIWorkspace.shared.resolve(try args.requiredString("path"))
        guard url.pathExtension.lowercased() == VideoEditProjectFile.fileExtension,
              FileManager.default.fileExists(atPath: url.path) else {
            throw AIToolError("\(url.path) is not an existing .\(VideoEditProjectFile.fileExtension) file.")
        }
        try refuseWhileRecording()
        // 已经开着：归这个会话的 / 没人剪的就用它；别的会话还在剪（5 分钟内调用过）就不做；安静久了就接手（方案 B.3）。
        if let existing = OpenProjects.shared.project(openAt: url) {
            let open = AIOpenProject(id: existing.shortID, stamp: sessions.stamp(existing), isPrimary: existing === OpenProjects.shared.primary)
            if case .refuse(let text) = AIProjectTargeting.decideOpen(existing: open, session: session, ownership: sessions.ownership, now: Date()) {
                throw AIToolError(text)
            }
            if inFront { OpenProjects.shared.reveal(existing) }
            return landed(existing, extra: ["opened": .string(url.path), "already_open": true])
        }
        try refuseAtCap()
        let project: VideoEditProject
        if inFront, sessions.primaryIsFree(for: session) {
            // 主窗口空着：装进去（一个会话剪一条时和以前一模一样），摆到前面一次。
            project = OpenProjects.shared.primary
            await project.openProject(at: url)
            guard let opened = project.documentURL, ProjectFileIdentity.same(opened, url) else {
                throw AIToolError(project.notice ?? "SrtFlow could not open \(url.lastPathComponent).")
            }
            try await AIEditorPresenter.prepareEditor(project: project, bringForward: true)
        } else {
            guard let opened = await OpenProjects.shared.openInWindow(url, inFront: inFront) else {
                throw AIToolError(OpenProjects.shared.failure ?? "SrtFlow could not open \(url.lastPathComponent).")
            }
            project = opened
        }
        var extra: [String: JSONValue] = [
            "opened": .string(url.path),
            "duration": AIFormat.seconds(project.state.duration),
            "clips": .number(Double(project.state.allClips.count))
        ]
        if !project.missingMedia.isEmpty { extra["missing_media"] = .array(project.missingMedia.map { .string($0.path) }) }
        return landed(project, extra: extra)
    }

    static func newProject(_ args: AIToolArguments, inFront: Bool) async throws -> AIToolResult {
        let workspace = AIWorkspace.shared
        let fallbackName = workspace.current?.lastPathComponent ?? L10n("Untitled")
        let stem = ExportFileName.stem(
            from: try args.string("name") ?? fallbackName, droppingExtension: VideoEditProjectFile.fileExtension, fallback: fallbackName
        )
        try refuseWhileRecording()
        try refuseAtCap()
        let primary = OpenProjects.shared.primary
        let folder = try args.string("folder").map { workspace.resolve($0) } ?? workspace.outputFolder(.projects, project: primary)
        // 撞名加编号，从不覆盖。
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: VideoEditProjectFile.fileExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project: VideoEditProject
        if inFront, sessions.primaryIsFree(for: session) {
            primary.newProject()
            guard primary.documentURL == nil, primary.state.isEmpty, primary.saveDocument(as: url) else {
                throw AIToolError(primary.notice ?? "SrtFlow could not save the new project to \(url.path).")
            }
            project = primary
            try await AIEditorPresenter.prepareEditor(project: project, bringForward: true)
        } else {
            guard let created = OpenProjects.shared.newInWindow(savingAs: url, inFront: inFront) else {
                throw AIToolError(OpenProjects.shared.failure ?? "SrtFlow could not save the new project to \(url.path).")
            }
            project = created
        }
        return landed(project, extra: ["created": .string(url.path)])
    }

    static func closeProject(_ args: AIToolArguments) throws -> AIToolResult {
        guard let id = try args.string("project") else {
            throw AIToolError("Pass project: the id (p1, p2…) open_project or new_project gave you.")
        }
        guard let project = OpenProjects.shared.project(shortID: id), sessions.owner(of: project)?.session == session else {
            throw AIToolError("Not closed: \(id) is not one of your open projects. Only close projects you opened or created.")
        }
        try refuseWhileRecording()
        let busy = AIJobs.shared.running.filter { $0.project == id }
        guard busy.isEmpty else {
            throw AIToolError("Not closed: \(id) still has a job running (\(busy.map(\.id).joined(separator: ", "))). "
                + "Wait for it with get_job or stop it with cancel_job, then close the project.")
        }
        let stamp = sessions.stamp(project)
        let path = project.documentURL?.path
        if project === OpenProjects.shared.primary {
            // 主窗口永远有一个工程：替它存好，再换成一个空的 Untitled（换之前没存过的先存进 SrtFlow/工程，不弹框）。
            if project.isUntitled, !project.state.isEmpty, AIProjectTools.saveUntitled(project) == nil {
                throw AIToolError("Not closed: SrtFlow could not save \(id) (\(project.notice ?? "unknown error")).")
            }
            guard project.flushAutosave(), OpenProjects.shared.resetPrimary() else {
                throw AIToolError("Not closed: SrtFlow could not save \(id) (\(project.notice ?? "unknown error")).")
            }
            sessions.release(project)
        } else {
            guard OpenProjects.shared.close(project) else {
                throw AIToolError("Not closed: SrtFlow could not save \(id) (\(project.notice ?? "unknown error")).")
            }
            sessions.release(project)
        }
        var payload: [String: JSONValue] = ["closed": .string(id)]
        if let path { payload["saved_to"] = .string(path) }
        let remaining = sessions.projects(of: session).map(\.shortID)
        payload["your_open_projects"] = .array(remaining.map { .string($0) })
        var result = AIToolResult.ok(.object(payload))
        result.stamp = stamp
        return result
    }

    // MARK: 共用

    /// 开 / 建完：归这个会话、记下它的工作区文件夹、「撤销这一轮」的快照换成它，结果带上短 id 和放在哪。
    private static func landed(_ project: VideoEditProject, extra: [String: JSONValue]) -> AIToolResult {
        sessions.own(project, session: session, client: client)
        AIWorkspace.shared.noteProjectOpened(project.shortID, session: session)
        AISession.shared.round(for: project).rebase(project: project)
        var payload = extra
        payload["project"] = .string(project.shortID)
        payload["shown_in"] = .string(project === OpenProjects.shared.primary ? "main window" : "own window")
        payload["next_step"] = .string("Pass project=\"\(project.shortID)\" on the calls for this project, "
            + "especially when you edit several at once (calls without project go to the one you opened last).")
        var result = AIToolResult.ok(.object(payload))
        result.stamp = sessions.stamp(project)
        return result
    }

    /// 开到顶了（方案板 2）：说清楚能先关哪几个（这个会话的、存过盘、没有任务在跑的）。
    private static func refuseAtCap() throws {
        guard OpenProjects.shared.all.count >= OpenProjects.limit else { return }
        let busy = Set(AIJobs.shared.running.compactMap(\.project))
        let closable = sessions.projects(of: session).filter { !$0.isUntitled && !busy.contains($0.shortID) }.map(sessions.stamp)
        throw AIToolError(AIProjectTargeting.capReached(limit: OpenProjects.limit, closable: closable))
    }

    /// 录屏进行中不许开 / 建 / 关工程（主窗口那个可能正是录好的素材要落进去的工程；关窗口的把关在录屏中也一律拒）：
    /// 界面那句「先停止录屏」AI 照做不了，换成它能照做的话。
    private static func refuseWhileRecording() throws {
        if ScreenRecordingCoordinator.shared.locksProjectSwitching {
            throw AIToolError(AIScreenRecordingTool.lockMessage("projects cannot be opened, created or closed now"))
        }
    }
}

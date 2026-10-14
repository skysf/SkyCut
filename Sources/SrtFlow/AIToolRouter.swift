import Foundation
import SrtFlowMCPKit

// MARK: - 一次工具调用怎么走
//
// 管什么：从通道上收到的调用 → 查停止、记这一轮 → 排队 → 摆出剪辑页 → 交给对应的工具 → 结果。
// switch 对 `MCPToolName` 是穷举的：清单里加了工具、这里没接，编译不过。
// 不管什么：收发（AIBridgeServer）、工具本身（AI*Tools）。
//
// **排队**：改工程的调用一个接一个做，按到达的顺序。Claude 会在一条消息里并排发几个调用，
// 不排队的话「接在 V1 最后」这种落点就看谁先探完素材，每次结果都不一样。
// 只读、会等很久的（get_job 最多等 30 秒）和取消不排队，免得堵住后面的活、或者取消排在被取消的后面。

@MainActor
final class AIToolRouter {
    static let shared = AIToolRouter()

    private var tail: Task<Void, Never>?

    private init() {}

    /// 一次调用的回答：结果，和这次用到（或刚换上）的工程 —— 小程序据此记住这个会话在剪哪一个（`MCPSessionProject`）。
    struct Answer {
        var result: JSONValue
        var project: MCPBridge.ProjectStamp?
    }

    /// 谁把开着的工程换成了现在这个（按工程代号记）：AI 的 open_project / new_project 做成时记下会话号和客户端；
    /// 没记过的 = 用户在界面上换的（`AIProjectBinding.refusal` 据此说清楚是谁）。
    private var switches: [Int: AIProjectBinding.Switch] = [:]

    /// `begin`：轮到这个调用时（排完队之后）先问一句 —— 小程序不等了（App 卡过、它放弃了）就回 false，不做（AIBridgeCalls）。
    func handle(_ request: MCPBridge.Request, begin: @escaping @Sendable () -> Bool) async -> Answer {
        guard request.bridge == MCPBridge.version else {
            return Answer(result: MCPBridge.textResult(
                "This SrtFlow and its AI helper come from different versions. Ask the user to restart the AI app.",
                isError: true
            ))
        }
        guard let tool = MCPToolName(rawValue: request.tool) else {
            return Answer(result: MCPBridge.textResult(
                "This SrtFlow does not have the tool \(request.tool). Ask the user to update SrtFlow.", isError: true
            ))
        }
        let session = AISession.shared
        if let refusal = session.refusalAfterStop() { return Answer(result: MCPBridge.textResult(refusal, isError: true)) }
        session.noteCall(client: request.client)
        let arguments = AIToolArguments(request.arguments)
        let policy = Policy(tool)
        guard policy.serialized else { return await execute(tool, arguments, policy, request, begin) }
        let previous = tail
        let work = Task { @MainActor () -> Answer in
            await previous?.value
            return await self.execute(tool, arguments, policy, request, begin)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func execute(
        _ tool: MCPToolName, _ arguments: AIToolArguments, _ policy: Policy, _ request: MCPBridge.Request,
        _ begin: @Sendable () -> Bool
    ) async -> Answer {
        // 小程序已经不等了（App 卡住的时候它放弃了这个调用、告诉 AI「没做，以后也不会做」）：照它说的，不做。
        guard begin() else {
            return Answer(result: MCPBridge.textResult("Not done: the AI helper stopped waiting for this call.", isError: true))
        }
        let project = VideoEditProject.shared
        // 排队期间用户按了停止：排在后面的也不做了。
        if policy.startsRound, AISession.shared.phase == .stopped {
            return Answer(result: MCPBridge.textResult(
                "The user pressed Stop in SrtFlow. Stop calling tools and ask the user what to do next.", isError: true
            ))
        }
        // 开着的不是这个会话的工程（别的会话或用户换了、App 重启过）：一样都不做，也不摆窗口、不开一轮。
        // 排到它这一刻才查 —— 排队时前面可能正是别人的 open_project（docs/architecture/ai-control-mcp.md 第四节第 46 条）。
        let usesProject = AIProjectBinding.usesProject(tool, arguments)
        if usesProject, let refusal = AIProjectBinding.refusal(
            expected: request.project, current: stamp(project), session: request.session,
            switchedBy: switches[project.documentGeneration]
        ) {
            return Answer(result: MCPBridge.textResult(refusal, isError: true))
        }
        let switchesProject = tool == .openProject || tool == .newProject
        let result = await run(tool, arguments, policy, project)
        if switchesProject, result["isError"]?.boolValue != true {
            switches[project.documentGeneration] = AIProjectBinding.Switch(
                session: request.session, client: AISession.displayName(for: request.client ?? "AI")
            )
        }
        return Answer(result: result, project: usesProject || switchesProject ? stamp(project) : nil)
    }

    /// 开着的工程是谁（`MCPBridge.ProjectStamp`）。
    private func stamp(_ project: VideoEditProject) -> MCPBridge.ProjectStamp {
        MCPBridge.ProjectStamp(
            token: AIProjectBinding.token(generation: project.documentGeneration),
            path: project.documentURL?.path, name: project.projectName
        )
    }

    private func run(_ tool: MCPToolName, _ arguments: AIToolArguments, _ policy: Policy, _ project: VideoEditProject) async -> JSONValue {
        do {
            // 窗口只在一轮开始时摆到前面（docs/plans/2026-09-27-mcp.md 第 32 条）：这一轮中途不再一步一跳；
            // 后台模式（第 7 条）一次都不摆。
            if policy.presentsEditor {
                let startsNewRound = AISession.shared.phase != .working
                let visible = AISession.shared.viewMode == .visible
                // 正在录屏时不摆：摆到前面就盖住正在录的画面、被录进去（docs/plans/2026-10-03-screen-recording-mcp.md 第 6 条）。
                let recordingScreen = ScreenRecordingCoordinator.shared.isBusy
                try await AIEditorPresenter.prepareEditor(project: project, bringForward: startsNewRound && visible && !recordingScreen)
            }
            if policy.startsRound { AISession.shared.beginRoundIfNeeded(project: project) }
            let result = try await dispatch(tool, arguments, project)
            guard result.changedProject else { return result.json }
            AISession.shared.noteChange()
            // 改的是一个从来没存过的工程：马上存下来，之后交给自动保存（见那个函数）。
            return AIProjectTools.saveIfNeverSaved(project, after: result).json
        } catch let error as AIToolError {
            return MCPBridge.textResult(error.message, isError: true)
        } catch {
            return MCPBridge.textResult("SrtFlow could not do that: \(error.localizedDescription)", isError: true)
        }
    }

    /// 改工程的同步工具各包一层 `AIUndoGrouping.step`：一个工具 = 一步撤销（为什么不能靠按事件分组，见那个文件）。
    /// 异步的 add_clips 在它自己那一次 perform 外面包；edit_clip 先 await 看画面、再把同步的提交包起来；
    /// freeze_frame 抽帧转码要 await，把「提交那一下」交给定格去包（AIClipTools.freeze）；
    /// 撤销的「一轮」在 AIProjectTools.undo 里包。
    private func dispatch(_ tool: MCPToolName, _ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let undo = project.effectiveUndoManager
        switch tool {
        case .getStatus: return try AIProjectTools.status(args, project)
        case .setView: return try AIProjectTools.setView(args)
        case .openFolder: return try await AIProjectTools.openFolder(args, project)
        case .readDocument: return try await AIFileTools.readDocument(args, project)
        case .recipes: return try AIRecipeTools.recipes(args)
        case .saveRecipe:
            let result = try AIRecipeTools.save(args)
            AIRecipeLibrary.shared.refresh()
            return result
        case .manageFiles: return try AIFileTools.manageFiles(args, project)
        case .openProject: return try await AIProjectTools.openProject(args, project)
        case .newProject: return try AIProjectTools.newProject(args, project)
        case .saveProject: return try AIProjectTools.saveProject(args, project)
        case .undo: return try AIProjectTools.undo(args, project)
        case .seek: return try AIProjectTools.seek(args, project)
        case .getTimeline: return AITimelineTools.timeline(project)
        case .look: return try await AILookTool.look(args, project)
        case .listen: return try await AIListenTool.listen(args, project)
        case .findAudio: return try await AIAudioLibraryTools.findAudio(args)
        // 不改工程：只起一个任务、回任务号（成品放上时间线是 add_clips 的事）。
        case .generateMedia: return try await FalGenerateTool.generate(args, project)
        // 起一个任务、回任务号；做完那一下的换源在任务里自己包一层 AIUndoGrouping.step（AIUpscaleTool.land）。
        case .upscaleClip: return try AIUpscaleTool.upscale(args, project)
        // 起一个录屏会话就回来（AI 好接着操作电脑）；入轨那一下是异步落账，会话的 landing 包一层 AIUndoGrouping.step。
        case .recordScreen: return try await AIScreenRecordingTool.run(args, project)
        case .addVoiceover:
            // 只是下载 SrtFlow 自己的声音：回任务号，不改工程。
            if let download = try await AIVoiceoverTool.startDownloadIfAsked(args) { return download }
            // 克隆的素材要发给 fal.ai：点名的文件夹以外的先问一次。
            if let ask = try AIVoiceoverTool.confirmations(args, project) { return ask }
            // 先合成（要 await），再把同步的提交包起来（同 edit_clip）。
            let plan = try await AIVoiceoverTool.plan(args, project)
            return try AIUndoGrouping.step(undo) { try AIVoiceoverTool.apply(plan, project) }
        case .transcribe:
            guard #available(macOS 26.0, *) else { throw AIToolError("Transcribing speech needs macOS 26 or later on this Mac.") }
            return try await AITranscribeTool.transcribe(args, project)
        case .compressVideos: return try await AIEncodeTools.compress(args, project)
        case .burnSubtitles: return try await AIEncodeTools.burnIn(args, project)
        case .convertSubtitles: return try AIEncodeTools.convert(args, project)
        case .addClips: return try await AITimelineTools.addClips(args, project)
        case .editClip:
            // 先看画面（去黑边、对准主体要抽帧），再同步提交：包进撤销组的那一段不许有 await。
            let plan = try await AIClipTools.plan(args, project)
            return try AIUndoGrouping.step(undo) { try AIClipTools.apply(plan, project) }
        case .setKeyframes: return try AIUndoGrouping.step(undo) { try AITimelineTools.setKeyframes(args, project) }
        case .setTrack: return try AIUndoGrouping.step(undo) { try AITimelineTools.setTrack(args, project) }
        case .splitClip: return try AIUndoGrouping.step(undo) { try AITimelineTools.split(args, project) }
        case .freezeFrame: return try await AIClipTools.freeze(args, project)
        case .cutSpeech:
            // 先 await 量声音、读转写，再把同步的那一下包起来（同 edit_clip）。
            let plan = try await AISpeechCutTool.plan(args, project)
            return try AIUndoGrouping.step(undo) { try AISpeechCutTool.apply(plan, project) }
        case .cutToBeat:
            let plan = try await AIBeatCutTool.plan(args, project)
            return try AIUndoGrouping.step(undo) { try AIBeatCutTool.apply(plan, project) }
        case .deleteItems: return try AIUndoGrouping.step(undo) { try AITimelineTools.delete(args, project) }
        case .duplicateItems: return try AIUndoGrouping.step(undo) { try AITimelineTools.duplicate(args, project) }
        case .setTransition: return try AIUndoGrouping.step(undo) { try AITimelineTools.transition(args, project) }
        case .setText: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setText(args, project) }
        case .setShape: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setShape(args, project) }
        case .setFilter: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setFilter(args, project) }
        case .setCanvas: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setCanvas(args, project) }
        case .generateSubtitles: return try await AISubtitleTools.generate(args, project)
        case .translateSubtitles: return try await AISubtitleTools.translate(args, project)
        case .getSubtitles: return try AISubtitleTools.read(args, project)
        case .editSubtitles:
            // 给了字体要先等字体表（await），再同步提交：包进撤销组的那一段不许有 await。
            let style = try await AISubtitleTools.style(args)
            return try AIUndoGrouping.step(undo) { try AISubtitleTools.edit(args, style: style, project) }
        case .exportVideo: return try await AIExportTools.export(args, project)
        case .getJob: return try await AIExportTools.job(args)
        case .cancelJob: return try AIExportTools.cancel(args)
        }
    }

    /// 每个工具的三件事：排不排队、要不要把剪辑页摆出来、算不算这一轮的改动。
    private struct Policy {
        let serialized: Bool
        let presentsEditor: Bool
        let startsRound: Bool

        init(_ tool: MCPToolName) {
            switch tool {
            case .getStatus, .getJob, .cancelJob:
                (serialized, presentsEditor, startsRound) = (false, false, false)
            // 套路不碰工程：不排队、不摆窗口、不算这一轮的改动。
            case .recipes, .saveRecipe:
                (serialized, presentsEditor, startsRound) = (false, false, false)
            case .setView:
                (serialized, presentsEditor, startsRound) = (true, false, false)
            case .openFolder, .readDocument, .manageFiles, .getTimeline, .look, .listen, .transcribe, .findAudio, .getSubtitles,
                 .saveProject, .exportVideo, .compressVideos, .burnSubtitles, .convertSubtitles, .generateMedia:
                (serialized, presentsEditor, startsRound) = (true, false, false)
            case .seek:
                (serialized, presentsEditor, startsRound) = (true, true, false)
            // 录屏不摆剪辑页（会盖住要录的画面、被录进去）；录完入轨算这一轮的改动。
            case .recordScreen:
                (serialized, presentsEditor, startsRound) = (true, false, true)
            case .openProject, .newProject, .undo, .addClips, .addVoiceover, .editClip, .setKeyframes, .setTrack, .splitClip, .deleteItems,
                 .duplicateItems, .freezeFrame, .cutSpeech, .cutToBeat,
                 .setTransition, .setText, .setShape, .setFilter, .setCanvas, .generateSubtitles, .translateSubtitles,
                 .editSubtitles, .upscaleClip:
                (serialized, presentsEditor, startsRound) = (true, true, true)
            }
        }
    }
}

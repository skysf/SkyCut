import Foundation
import SrtFlowMCPKit

// MARK: - 一次工具调用怎么走
//
// 管什么：从通道上收到的调用 → 核对参数名（MCPArgumentCheck）→ 查停止、记这一轮 → 排队 → 定下落在哪个工程（几个工程、几个会话时）→ 摆出剪辑页 → 交给对应的工具 → 结果。
// switch 对 `MCPToolName` 是穷举的：清单里加了工具、这里没接，编译不过。
// 不管什么：收发（AIBridgeServer）、工具本身（AI*Tools）、落在哪 / 归谁的规矩（AIProjectTargeting / AIProjectSessions）。
//
// **排队按工程**（docs/plans/2026-10-17-multi-project-ai-editing.md C 节）：碰工程的调用按工程排（同一个工程的调用仍一个接一个，
// 「接在 V1 最后」看谁先探完素材就不会乱），不碰工程的按会话排，不同工程之间不互相等 —— 以前全 App 一条队，五个子代理的调用一个接一个，
// 谁在 await（探素材、认画面、合成配音）别人全等着。开 / 建 / 关工程按会话另一条：不带 `project` 的调用先等这个会话还没做完的
// 开 / 建 / 关（它们决定了「最后打开的那个」），再按那时落在的工程排。
// 只读、会等很久的（get_job 最多等 30 秒）和取消不排队，免得堵住后面的活、或者取消排在被取消的后面。
// **排到之后、动窗口之前**才定落在哪个工程、查归属（排队时前面可能正是别人的 open_project / close_project）。

@MainActor
final class AIToolRouter {
    static let shared = AIToolRouter()

    /// 每条队的队尾（键："project:p2"、"session:<会话>"、"switch:<会话>"）。
    private var tails: [String: Task<Void, Never>] = [:]

    private init() {}

    /// 一次调用的回答：结果，和这次用到（或刚开 / 建 / 关）的工程 —— 小程序据此记这个会话的一组工程（`MCPSessionProject`）。
    struct Answer {
        var result: JSONValue
        var project: MCPBridge.ProjectStamp?
    }

    /// `begin`：轮到这个调用时（排完队之后）先问一句 —— 小程序不等了（App 卡过、它放弃了）就回 false，不做（AIBridgeCalls）。
    func handle(_ request: MCPBridge.Request, begin: @escaping @Sendable () -> Bool) async -> Answer {
        guard request.bridge == MCPBridge.version else {
            return Answer(result: MCPBridge.textResult(
                "This SkyCut and its AI helper come from different versions. Ask the user to restart the AI app.",
                isError: true
            ))
        }
        guard let tool = MCPToolName(rawValue: request.tool) else {
            return Answer(result: MCPBridge.textResult(
                "This SkyCut does not have the tool \(request.tool). Ask the user to update SkyCut.", isError: true
            ))
        }
        // 说明上没有的参数名：整个调用不做，告诉 AI 哪个名字不对、这里收哪些（以前直接丢掉，见 MCPArgumentCheck）。
        if let problem = MCPArgumentCheck.problem(tool: tool, arguments: request.arguments) {
            return Answer(result: MCPBridge.textResult(problem, isError: true))
        }
        let call = Call(
            tool: tool, arguments: AIToolArguments(request.arguments), policy: Policy(tool), request: request,
            session: request.session ?? AIProjectSessions.anonymous, client: AISession.displayName(for: request.client ?? "AI")
        )
        AIProjectSessions.shared.noteCall(session: call.session)
        guard call.policy.serialized else { return await execute(call, begin) }
        return await enqueue(await queueKeys(call)) { await self.execute(call, begin) }
    }

    /// 一次调用要用的东西，排队、定工程、执行都传它。
    private struct Call {
        let tool: MCPToolName
        let arguments: AIToolArguments
        let policy: Policy
        let request: MCPBridge.Request
        let session: String
        let client: String

        var explicitProject: String? { try? arguments.string("project") }
        var switchesProject: Bool { tool == .openProject || tool == .newProject || tool == .closeProject }
    }

    /// 排在哪几条队后面（C 节）。不带 `project` 的碰工程的调用，先等这个会话还没做完的开 / 建 / 关。
    private func queueKeys(_ call: Call) async -> [String] {
        if call.switchesProject {
            // 关一个工程要等它自己那条队上正在做的活做完。
            return ["switch:" + call.session] + (call.tool == .closeProject ? call.explicitProject.map { ["project:" + $0] } ?? [] : [])
        }
        guard AIProjectBinding.usesProject(call.tool, call.arguments) else { return ["session:" + call.session] }
        if let id = call.explicitProject { return ["project:" + id] }
        await tails["switch:" + call.session]?.value
        let sessions = AIProjectSessions.shared
        let id = sessions.ownership.current(of: call.session) ?? OpenProjects.shared.primary.shortID
        return ["project:" + id]
    }

    private func enqueue(_ keys: [String], _ work: @escaping @MainActor () async -> Answer) async -> Answer {
        let previous = keys.compactMap { tails[$0] }
        let task = Task { @MainActor () -> Answer in
            for tail in previous { await tail.value }
            return await work()
        }
        let done = Task { _ = await task.value }
        for key in keys { tails[key] = done }
        return await task.value
    }

    private func execute(_ call: Call, _ begin: @Sendable () -> Bool) async -> Answer {
        // 小程序已经不等了（App 卡住的时候它放弃了这个调用、告诉 AI「没做，以后也不会做」）：照它说的，不做。
        guard begin() else {
            return Answer(result: MCPBridge.textResult("Not done: the AI helper stopped waiting for this call.", isError: true))
        }
        let sessions = AIProjectSessions.shared
        // 碰工程的：落在哪个工程上、能不能落（别的会话的不许碰、App 重启过、关掉了……一样都不做，也不摆窗口、不开一轮）。
        // 排到它这一刻才定（docs/architecture/ai-control-mcp.md 第四节第 46 条）。
        var target: VideoEditProject?
        if AIProjectBinding.usesProject(call.tool, call.arguments) {
            switch sessions.target(
                explicitID: call.explicitProject, remembered: call.request.project, session: call.session, client: call.client
            ) {
            case .failure(let refusal): return Answer(result: MCPBridge.textResult(refusal.message, isError: true))
            case .success(let project): target = project
            }
        }
        // 用户在这个工程上按了停止（排队期间按的也算）：AI 安静下来之前落在它上面的调用都不做（AIRound）。别的工程照剪。
        if let target {
            let round = AISession.shared.round(for: target)
            if let refusal = round.refusalAfterStop() { return Answer(result: MCPBridge.textResult(refusal, isError: true)) }
            round.noteCall(client: call.request.client)
        } else {
            // 不碰工程的调用（等导出、看文件……）：这个会话还在剪，它的几个工程的这一轮都还没完。
            for project in sessions.projects(of: call.session) { AISession.shared.round(for: project).noteActivity() }
        }
        // 不碰工程的（看文件、开文件夹……）照旧要一个工程给工具读写默认值：这个会话最后打开的那个，没有就是主窗口那个。
        let project = target ?? sessions.projects(of: call.session).last ?? OpenProjects.shared.primary
        let context = AICallContext(session: call.session, client: call.client, project: target?.shortID, stopsWith: project.shortID)
        let outcome = await AICallContext.$current.withValue(context) { await run(call, project, onProject: target != nil) }
        // 开 / 建 / 关回它开 / 建 / 关的那个（工具结果里带着），别的碰工程的回它落在的那个；出错的不回（小程序记的不变）。
        let stamp = outcome.failed ? nil : outcome.stamp ?? target.map(sessions.stamp)
        return Answer(result: outcome.json, project: stamp)
    }

    private struct Outcome {
        var json: JSONValue
        var stamp: MCPBridge.ProjectStamp?
        var failed = false
    }

    private func run(_ call: Call, _ project: VideoEditProject, onProject: Bool) async -> Outcome {
        do {
            // 窗口只在开工程时摆一次（方案板 3，取代 docs/plans/2026-09-27-mcp.md 第 32 条「每一轮开始摆一次」）：工程窗口开的时候
            // 摆过（OpenProjects）、开 / 建进主窗口时摆过（AIProjectOpenTools）；会话第一次在主窗口那个（这一次打开）上做要摆剪辑页的事
            // 算它的「开」。后台模式（第 7 条）一次都不摆。主窗口的工程每次照样过 prepareEditor：窗口被关了要开回来、剪辑页要出现过（撤销管理器）。
            if call.policy.presentsEditor, onProject, project === OpenProjects.shared.primary {
                let visible = AISession.shared.viewMode(for: project) == .visible
                // 正在录屏时不摆：摆到前面就盖住正在录的画面、被录进去（docs/plans/2026-10-03-screen-recording-mcp.md 第 6 条）。
                let recordingScreen = ScreenRecordingCoordinator.shared.isBusy
                // 真摆了才记下（后台、录屏中不算摆过，之后看得见了、录完了还会摆一次）。
                let firstShow = visible && !recordingScreen && AISession.shared.claimFirstShow(of: project, session: call.session)
                try await AIEditorPresenter.prepareEditor(project: project, bringForward: firstShow)
            }
            // 录屏只留文件（不入轨）也开一轮：横幅和停止键照旧出来（同以前）。「撤销这一轮」的快照在开 / 建工程时换成那个工程。
            if call.policy.startsRound { AISession.shared.round(for: project).beginIfNeeded(project: project) }
            var result = try await dispatch(call.tool, call.arguments, project)
            if onProject { result.payload = Self.stamped(result.payload, with: project) }
            guard result.changedProject, onProject else { return Outcome(json: result.json, stamp: result.stamp) }
            AISession.shared.round(for: project).noteChange()
            // 改的是一个从来没存过的工程：马上存下来，之后交给自动保存（见那个函数）。
            return Outcome(json: AIProjectTools.saveIfNeverSaved(project, after: result).json, stamp: result.stamp)
        } catch let error as AIToolError {
            return Outcome(json: MCPBridge.textResult(error.message, isError: true), failed: true)
        } catch {
            return Outcome(json: MCPBridge.textResult("SkyCut could not do that: \(error.localizedDescription)", isError: true), failed: true)
        }
    }

    /// 新开 / 新建的工程摆不摆到前面：照这个会话的默认看法（方案 F 节）。
    private static var opensInFront: Bool {
        AISession.shared.defaultViewMode(session: AICallContext.current?.session ?? AIProjectSessions.anonymous) == .visible
    }

    /// 结果里带上这一步落在哪个工程（`project`: p2）：几个工程一起剪时 AI 一眼看得出来，子代理忘了带参数也看得出不对（方案 B.4）。
    private static func stamped(_ payload: JSONValue, with project: VideoEditProject) -> JSONValue {
        guard case .object(var object) = payload, object["project"] == nil else { return payload }
        object["project"] = .string(project.shortID)
        return .object(object)
    }

    /// 改工程的同步工具各包一层 `AIUndoGrouping.step`：一个工具 = 一步撤销（为什么不能靠按事件分组，见那个文件）。
    /// 异步的 add_clips 在它自己那一次 perform 外面包；edit_clip 先 await 看画面、再把同步的提交包起来；
    /// freeze_frame 抽帧转码要 await，把「提交那一下」交给定格去包（AIClipTools.freeze）；
    /// 撤销的「一轮」在 AIProjectTools.undo 里包。
    private func dispatch(_ tool: MCPToolName, _ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let undo = project.effectiveUndoManager
        switch tool {
        case .getStatus: return try AIProjectTools.status(args, project)
        case .setView: return try await AIProjectTools.setView(args, project)
        case .openFolder: return try await AIProjectTools.openFolder(args, project)
        case .readDocument: return try await AIFileTools.readDocument(args, project)
        case .recipes: return try AIRecipeTools.recipes(args)
        case .saveRecipe:
            let result = try AIRecipeTools.save(args)
            AIRecipeLibrary.shared.refresh()
            return result
        case .manageFiles: return try AIFileTools.manageFiles(args, project)
        case .openProject: return try await AIProjectOpenTools.openProject(args, inFront: Self.opensInFront)
        case .newProject: return try await AIProjectOpenTools.newProject(args, inFront: Self.opensInFront)
        case .closeProject: return try AIProjectOpenTools.closeProject(args)
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
        case .exportSubtitles: return try AISubtitleFileExport.export(args, project)
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
                 .saveProject, .exportVideo, .exportSubtitles, .compressVideos, .burnSubtitles, .convertSubtitles, .generateMedia:
                (serialized, presentsEditor, startsRound) = (true, false, false)
            case .seek:
                (serialized, presentsEditor, startsRound) = (true, true, false)
            // 录屏不摆剪辑页（会盖住要录的画面、被录进去）；录完入轨算这一轮的改动。
            case .recordScreen:
                (serialized, presentsEditor, startsRound) = (true, false, true)
            // 开 / 建 / 关工程：开在哪、摆不摆由它们自己定（主窗口空着装进去时摆一次，工程窗口开的时候摆一次）；不开一轮。
            case .openProject, .newProject, .closeProject:
                (serialized, presentsEditor, startsRound) = (true, false, false)
            case .undo, .addClips, .addVoiceover, .editClip, .setKeyframes, .setTrack, .splitClip, .deleteItems,
                 .duplicateItems, .freezeFrame, .cutSpeech, .cutToBeat,
                 .setTransition, .setText, .setShape, .setFilter, .setCanvas, .generateSubtitles, .translateSubtitles,
                 .editSubtitles, .upscaleClip:
                (serialized, presentsEditor, startsRound) = (true, true, true)
            }
        }
    }
}

import Foundation
import SrtFlowMCPKit

// 一个会话一组工程（2026-10-17 起，docs/plans/2026-10-17-multi-project-ai-editing.md 板 1、7；
// docs/architecture/ai-control-mcp.md 第四节第 46 条；更早的「一个会话一个工程」见
// docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md）。
// 1. 小程序记着这个会话的一组工程（`MCPSessionProject`）：open_project / new_project 收进来、成为最后打开的；close_project 拿掉、
//    退到剩下的里最近打开的；带 `project` 的请求带那一个的身份章，没带的带最后打开的；同一个工程跟着更新路径；
//    App 重启过的同名 id 是另一个工程；
// 2. 真起小程序：子代理并排带不同的 `project`，各带各的身份章；另起一个小程序是另一个会话号；
// 3. 哪些调用碰工程（读时间线也算，只看文件的不算）。
// 落在哪 / 归谁 / 什么时候拒在 ProjectTargetingChecks。路由在排到这个调用、动窗口之前定，扫描在 scripts/check-mcp.sh。

func runProjectBindingChecks() {
    runSessionMemoryChecks()
    runHelperBindingChecks()
    runUsesProjectChecks()
}

private let stampP1 = MCPBridge.ProjectStamp(token: "run1-1", path: nil, name: "Untitled", id: "p1")
private let stampA = MCPBridge.ProjectStamp(token: "run1-3", path: "/tmp/srtflow-binding/Wedding.srtflowproj", name: "Wedding", id: "p2")
private let stampB = MCPBridge.ProjectStamp(token: "run1-4", path: "/tmp/srtflow-binding/Edit.srtflowproj", name: "Edit", id: "p3")

private func answer(_ project: MCPBridge.ProjectStamp?, error: Bool = false) -> MCPBridge.Response {
    MCPBridge.Response(id: "x", result: MCPBridge.textResult(error ? "failed" : "{}", isError: error), project: project)
}

private func request(_ tool: String, project: String? = nil) -> MCPBridge.Request {
    MCPBridge.Request(tool: tool, arguments: project.map { ["project": .string($0)] } ?? [:], client: "c")
}

private func runSessionMemoryChecks() {
    let memory = MCPSessionProject()
    let first = memory.stamp(request("get_timeline"))
    check(first.project == nil, "a new session has no project yet")
    check(!(first.session ?? "").isEmpty, "every request carries the session id")
    check(MCPSessionProject().session != memory.session, "two helpers are two sessions")

    memory.note(tool: "get_timeline", response: answer(stampP1))
    checkEqual(memory.current, stampP1, "the first call that used a project (the main window's) becomes the session's project")
    memory.note(tool: "open_project", response: answer(stampA))
    checkEqual(memory.current, stampA, "open_project makes the opened project the last one")
    memory.note(tool: "new_project", response: answer(stampB))
    checkEqual(memory.current, stampB, "new_project makes the new project the last one")
    checkEqual(memory.all.map(\.id), ["p1", "p2", "p3"], "the session keeps all three, in the order it opened them")

    checkEqual(memory.stamp(request("add_clips")).project, stampB, "a call without project goes to the last opened")
    checkEqual(memory.stamp(request("add_clips", project: "p2")).project, stampA, "project=p2 sends p2's stamp")
    check(memory.stamp(request("add_clips", project: "p9")).project == nil,
          "an id the session does not know sends no stamp (the app answers by id)")

    var saved = stampA
    saved.path = "/tmp/srtflow-binding/Wedding 2.srtflowproj"
    saved.name = "Wedding 2"
    memory.note(tool: "save_project", response: answer(saved))
    checkEqual(memory.stamp(request("set_text", project: "p2")).project, saved, "p2 saved under another name keeps its new path")
    checkEqual(memory.current, stampB, "an answer about another project does not change the last opened")
    memory.note(tool: "add_clips", response: answer(nil))
    checkEqual(memory.current, stampB, "a refused call (no project in the answer) changes nothing")
    memory.note(tool: "open_project", response: answer(stampP1, error: true))
    checkEqual(memory.current, stampB, "a failed open_project changes nothing")

    memory.note(tool: "close_project", response: answer(stampB))
    checkEqual(memory.all.map(\.id), ["p1", "p2"], "close_project drops the project")
    checkEqual(memory.current, saved, "closing the last opened falls back to the most recently opened of the rest")
    memory.note(tool: "close_project", response: answer(stampP1, error: true))
    checkEqual(memory.all.count, 2, "a failed close_project changes nothing")

    // App 重启过：短 id 从 p1 重来，新一轮的 p2 不是旧的那个。
    let restartedP2 = MCPBridge.ProjectStamp(token: "run2-1", path: "/tmp/srtflow-binding/Other.srtflowproj", name: "Other", id: "p2")
    memory.note(tool: "open_project", response: answer(restartedP2))
    checkEqual(memory.all.count, 3, "after a restart a project with an old id is a different project, not an update")
    checkEqual(memory.stamp(request("look", project: "p2")).project, restartedP2, "project=p2 now means the newest p2")

    // 兼容：老 App 不回 project / id、老小程序不带 project / session —— 解出来是 nil，不是解码失败。
    let oldResponse = #"{"bridge":1,"id":"a","result":{"content":[],"isError":false},"project":{"token":"run1-5","name":"Old"}}"#
    let decoded = try? JSONDecoder().decode(MCPBridge.Response.self, from: Data(oldResponse.utf8))
    check(decoded != nil && decoded?.project?.id == nil, "an answer from an older SrtFlow (no project id) still decodes")
    let oldRequest = #"{"bridge":1,"id":"a","tool":"get_status","arguments":{}}"#
    let decodedRequest = try? JSONDecoder().decode(MCPBridge.Request.self, from: Data(oldRequest.utf8))
    check(decodedRequest != nil && decodedRequest?.project == nil && decodedRequest?.session == nil, "a request from an older helper still decodes")
}

/// 假 App：主窗口里一个 p1；open_project 开出 A（p2）、new_project 开出 B（p3）；带了 project 的调用回那一个，没带的回此刻最后开的。
/// 记下每次调用带来的工程和会话号。
private final class BindingFakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var seen: [MCPBridge.Request] = []
    private var last = stampP1

    init() throws {
        path = NSTemporaryDirectory() + "srtflow-mcp-binding-\(getpid()).sock"
        let fd = try MCPUnixSocket.listen(path: path)
        Thread { [weak self] in
            while let client = MCPUnixSocket.accept(fd) {
                guard let self, let line = try? MCPUnixSocket.readLine(client),
                      let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) else {
                    close(client)
                    continue
                }
                let project = self.handle(request)
                let response = MCPBridge.Response(id: request.id, result: MCPBridge.textResult("ok"), project: project)
                if let data = try? JSONEncoder().encode(response) { try? MCPUnixSocket.writeLine(client, data) }
                close(client)
            }
        }.start()
    }

    private func handle(_ request: MCPBridge.Request) -> MCPBridge.ProjectStamp? {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        switch request.tool {
        case "open_project": last = stampA
        case "new_project": last = stampB
        case "get_status": return nil
        default:
            if let id = request.arguments["project"]?.stringValue { return [stampP1, stampA, stampB].first { $0.id == id } }
        }
        return last
    }

    var requests: [MCPBridge.Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private func runHelperBindingChecks() {
    let app: BindingFakeApp
    do { app = try BindingFakeApp() } catch {
        check(false, "binding fake app could not listen: \(error)")
        return
    }
    func call(_ id: Int, _ tool: String, project: String? = nil) -> String {
        let arguments = project.map { #"{"project":"\#($0)"}"# } ?? "{}"
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
    }
    // 一批按顺序做完（小程序对批量请求一条条等回答）：开 A、建 B，之后子代理们带着各自的 project 来。
    let batch = "[" + [call(1, "open_project"), call(2, "add_clips"), call(3, "get_status"), call(4, "new_project"),
                       call(5, "set_text"), call(6, "add_clips", project: "p2"), call(7, "look", project: "p3")].joined(separator: ",") + "]"
    _ = talkToHelper([batch], socket: app.path)
    let first = app.requests
    checkEqual(first.map(\.tool), ["open_project", "add_clips", "get_status", "new_project", "set_text", "add_clips", "look"],
               "the helper forwarded the batch in order")
    guard first.count == 7 else { return }
    check(first[0].project == nil, "the first call of a session carries no project")
    checkEqual(first[1].project, stampA, "after open_project a call without project carries the project it opened")
    checkEqual(first[2].project, stampA, "a call that did not touch a project keeps the last opened")
    checkEqual(first[4].project, stampB, "after new_project a call without project carries the new project")
    checkEqual(first[5].project, stampA, "project=p2 carries p2's stamp even though p3 was opened last (sub-agent on p2)")
    checkEqual(first[6].project, stampB, "project=p3 carries p3's stamp")
    checkEqual(first[5].arguments["project"]?.stringValue, "p2", "the project argument itself reaches the app unchanged")
    let sessions = Set(first.compactMap(\.session))
    check(sessions.count == 1 && first.allSatisfy { !($0.session ?? "").isEmpty }, "one helper process = one session id on every call")

    _ = talkToHelper([call(1, "get_timeline")], socket: app.path)
    let second = app.requests.dropFirst(7)
    check(second.count == 1 && second.first?.session != nil && second.first?.session != first.first?.session,
          "another helper process (another AI session) has its own session id")
    check(second.first?.project == nil, "another session starts with no project even while the first one has three")
}

private func runUsesProjectChecks() {
    let none = args([:])
    for tool in MCPToolName.allCases {
        let expected: Bool
        switch tool {
        case .getStatus, .setView, .openFolder, .readDocument, .recipes, .saveRecipe, .manageFiles, .findAudio, .generateMedia,
             .compressVideos, .burnSubtitles, .convertSubtitles, .getJob, .cancelJob, .openProject, .newProject, .closeProject,
             .recordScreen:
            expected = false
        default:
            expected = true
        }
        checkEqual(AIProjectBinding.usesProject(tool, none), expected, "\(tool.rawValue) with no arguments uses a project")
    }
    let file: JSONValue = "clip.mp4"
    check(!AIProjectBinding.usesProject(.look, args(["file": file])), "look at a file does not use the project")
    check(!AIProjectBinding.usesProject(.look, args(["files": [file]])), "look at files does not use the project")
    check(AIProjectBinding.usesProject(.look, args(["time": 3])), "look at the timeline uses the project")
    check(!AIProjectBinding.usesProject(.listen, args(["file": file])), "listen to a file does not use the project")
    check(!AIProjectBinding.usesProject(.transcribe, args(["file": file])), "transcribe a file does not use the project")
    check(!AIProjectBinding.usesProject(.addVoiceover, args(["download_voices": true])), "downloading voices does not use the project")
    check(AIProjectBinding.usesProject(.recordScreen, args(["action": "start"])), "a recording that lands on the timeline uses the project")
    check(!AIProjectBinding.usesProject(.recordScreen, args(["action": "start", "add_to_timeline": false])),
          "a recording that only keeps the file does not")
    check(AIProjectBinding.usesProject(.recordScreen, args(["action": "resolve", "decision": "add"])), "resolve add lands on the timeline")
    check(!AIProjectBinding.usesProject(.recordScreen, args(["action": "stop"])), "stop only stops the recording")
    // 会改东西的工具，除了只碰文件 / 设置 / 任务、开关工程的那几个，全都碰工程（新加一个改工程的工具忘了归类，这里红）。
    let fileOnly: Set<MCPToolName> = [.setView, .saveRecipe, .manageFiles, .openProject, .newProject, .closeProject, .compressVideos,
                                      .burnSubtitles, .convertSubtitles, .generateMedia, .cancelJob, .recordScreen]
    for tool in MCPToolName.allCases where !tool.definition.readOnly && !fileOnly.contains(tool) {
        check(AIProjectBinding.usesProject(tool, none), "\(tool.rawValue) changes something, so it must check the project")
    }
    // 收 `project` 参数的和碰工程的对得上：碰工程的都收（不然 AI 没法指定），不碰工程的除了录屏 / 关工程都不收（不然参数白给）。
    for tool in MCPToolName.allCases {
        let properties = tool.definition.inputSchema["properties"]?.objectValue ?? [:]
        let takes = properties["project"] != nil
        checkEqual(takes, tool.takesProject, "\(tool.rawValue): the project parameter is in the schema exactly when takesProject")
        if AIProjectBinding.usesProject(tool, none) { check(takes, "\(tool.rawValue) uses a project, so it takes project") }
    }
}

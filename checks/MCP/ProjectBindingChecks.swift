import Foundation
import SrtFlowMCPKit

// 几个 AI 会话共用一个 SrtFlow：每个会话只改自己的工程（docs/architecture/ai-control-mcp.md 第四节第 46 条，
// docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md）。
// 1. 小程序记着这个会话的工程（`MCPSessionProject`）：第一次碰工程时记下、open_project / new_project 做成了才换、
//    别的工程的回答不顶掉它、同一个工程跟着更新路径；
// 2. 真起小程序：open_project 之后的调用带着那个工程和同一个会话号，另起一个小程序是另一个会话号；
// 3. App 这头的判断（`AIProjectBinding`）：不是同一个工程就拒、说清楚是谁换的和怎么回去，同一个文件 / 自己刚换的不拒；
//    哪些调用碰工程（读时间线也算，只看文件的不算）。
// 路由在排到这个调用、动窗口之前查，扫描在 scripts/check-mcp.sh。

func runProjectBindingChecks() {
    runSessionMemoryChecks()
    runHelperBindingChecks()
    runRefusalChecks()
    runUsesProjectChecks()
}

private let stampA = MCPBridge.ProjectStamp(token: "run1-3", path: "/tmp/srtflow-binding/Wedding.srtflowproj", name: "Wedding")
private let stampB = MCPBridge.ProjectStamp(token: "run1-4", path: "/tmp/srtflow-binding/Edit.srtflowproj", name: "Edit")

private func answer(_ project: MCPBridge.ProjectStamp?, error: Bool = false) -> MCPBridge.Response {
    MCPBridge.Response(id: "x", result: MCPBridge.textResult(error ? "failed" : "{}", isError: error), project: project)
}

private func runSessionMemoryChecks() {
    let memory = MCPSessionProject()
    let first = memory.stamp(MCPBridge.Request(tool: "get_timeline", arguments: [:], client: "c"))
    check(first.project == nil, "a new session has no project yet")
    check(!(first.session ?? "").isEmpty, "every request carries the session id")
    check(MCPSessionProject().session != memory.session, "two helpers are two sessions")

    memory.note(tool: "get_timeline", response: answer(stampA))
    checkEqual(memory.current, stampA, "the first call that used a project binds the session to it")
    memory.note(tool: "add_clips", response: answer(stampB))
    checkEqual(memory.current, stampA, "an answer about another project does not rebind (only open_project / new_project do)")
    memory.note(tool: "add_clips", response: answer(nil))
    checkEqual(memory.current, stampA, "a refused call (no project in the answer) keeps the binding")
    var saved = stampA
    saved.path = "/tmp/srtflow-binding/Wedding 2.srtflowproj"
    saved.name = "Wedding 2"
    memory.note(tool: "save_project", response: answer(saved))
    checkEqual(memory.current, saved, "the same project saved under another name keeps the binding with the new path")
    memory.note(tool: "open_project", response: answer(stampB, error: true))
    checkEqual(memory.current, saved, "a failed open_project does not rebind")
    memory.note(tool: "open_project", response: answer(stampB))
    checkEqual(memory.current, stampB, "open_project rebinds to what it opened")
    let created = MCPBridge.ProjectStamp(token: "run1-9", path: "/tmp/srtflow-binding/New.srtflowproj", name: "New")
    memory.note(tool: "new_project", response: answer(created))
    checkEqual(memory.current, created, "new_project rebinds to what it created")
    checkEqual(memory.stamp(MCPBridge.Request(tool: "add_clips", arguments: [:], client: nil)).project, created,
               "later requests carry the bound project")

    // 兼容：老 App 不回 project、老小程序不带 project / session —— 解出来是 nil，不是解码失败。
    let oldResponse = #"{"bridge":1,"id":"a","result":{"content":[],"isError":false}}"#
    let decoded = try? JSONDecoder().decode(MCPBridge.Response.self, from: Data(oldResponse.utf8))
    check(decoded != nil && decoded?.project == nil, "an answer from an older SrtFlow (no project) still decodes")
    let oldRequest = #"{"bridge":1,"id":"a","tool":"get_status","arguments":{}}"#
    let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: Data(oldRequest.utf8))
    check(request != nil && request?.project == nil && request?.session == nil, "a request from an older helper still decodes")
}

/// 假 App：开着一个工程；open_project 换成 A、new_project 换成 B，别的调用回此刻开着的那个。记下每次调用带来的工程和会话号。
private final class BindingFakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var seen: [MCPBridge.Request] = []
    private var open: MCPBridge.ProjectStamp?

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
        case "open_project": open = stampA
        case "new_project": open = stampB
        case "get_status": return nil
        default: break
        }
        return open
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
    func call(_ id: Int, _ tool: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#
    }
    // 一批按顺序做完（小程序对批量请求一条条等回答），open_project 的回答回来之后才发下一个。
    let batch = "[" + [call(1, "open_project"), call(2, "add_clips"), call(3, "get_status"), call(4, "new_project"),
                       call(5, "set_text")].joined(separator: ",") + "]"
    _ = talkToHelper([batch], socket: app.path)
    let first = app.requests
    checkEqual(first.map(\.tool), ["open_project", "add_clips", "get_status", "new_project", "set_text"], "the helper forwarded the batch in order")
    guard first.count == 5 else { return }
    check(first[0].project == nil, "the first call of a session carries no project")
    checkEqual(first[1].project, stampA, "after open_project the helper sends the project it opened")
    checkEqual(first[2].project, stampA, "a call that did not touch the project keeps the binding")
    checkEqual(first[4].project, stampB, "after new_project the helper sends the new project")
    let sessions = Set(first.compactMap(\.session))
    check(sessions.count == 1 && first.allSatisfy { !($0.session ?? "").isEmpty }, "one helper process = one session id on every call")

    _ = talkToHelper([call(1, "get_timeline")], socket: app.path)
    let second = app.requests.dropFirst(5)
    check(second.count == 1 && second.first?.session != nil && second.first?.session != first.first?.session,
          "another helper process (another AI session) has its own session id")
    check(second.first?.project == nil, "another session starts unbound even while the first one was bound")
}

private func runRefusalChecks() {
    let run = "run1"
    func refusal(_ expected: MCPBridge.ProjectStamp?, _ current: MCPBridge.ProjectStamp,
                 session: String? = "s1", switchedBy: AIProjectBinding.Switch? = nil) -> String? {
        AIProjectBinding.refusal(expected: expected, current: current, session: session, switchedBy: switchedBy, run: run)
    }
    check(refusal(nil, stampB) == nil, "a session that never touched a project is not refused")
    check(refusal(stampA, stampA) == nil, "the session's own project is open: not refused")
    var reopened = stampA
    reopened.token = "run1-12"
    check(refusal(stampA, reopened) == nil, "the same file closed and opened again is the same project")
    check(refusal(stampA, stampB, switchedBy: .init(session: "s1", client: "Claude Code")) == nil,
          "the session switched the project itself (calls sent side by side): not refused")

    let byAnother = refusal(stampA, stampB, switchedBy: .init(session: "s2", client: "Claude")) ?? ""
    check(byAnother.contains("another AI session (Claude)"), "says another AI session switched the project: \(byAnother)")
    check(byAnother.contains(stampA.path!) && byAnother.contains(stampB.path!), "names both projects by path")
    check(byAnother.contains("Nothing was changed"), "says nothing was changed")
    check(byAnother.contains("open_project with path \"\(stampA.path!)\""), "says how to go back to its own project")
    check(byAnother.contains("ask the user"), "tells the AI to ask the user before switching")

    let byUser = refusal(stampA, stampB) ?? ""
    check(byUser.contains("the user switched SrtFlow"), "nobody recorded the switch: the user did it in SrtFlow")

    let restarted = refusal(MCPBridge.ProjectStamp(token: "run0-3", path: stampA.path, name: "Wedding"),
                            MCPBridge.ProjectStamp(token: "run1-0", path: nil, name: "Untitled")) ?? ""
    check(restarted.contains("restarted"), "an older run's project: SrtFlow was restarted")
    check(restarted.contains("never saved") && restarted.contains("Command-S"),
          "the open project was never saved: says so and how to make it openable")

    let unsavedOwn = refusal(MCPBridge.ProjectStamp(token: "run1-2", path: nil, name: "Untitled"), stampB) ?? ""
    check(unsavedOwn.contains("cannot be opened again"), "the session's own project was never saved: says it cannot come back")
}

private func runUsesProjectChecks() {
    let none = args([:])
    for tool in MCPToolName.allCases {
        let expected: Bool
        switch tool {
        case .getStatus, .setView, .openFolder, .readDocument, .recipes, .saveRecipe, .manageFiles, .findAudio, .generateMedia,
             .compressVideos, .burnSubtitles, .convertSubtitles, .getJob, .cancelJob, .openProject, .newProject, .recordScreen:
            expected = false
        default:
            expected = true
        }
        checkEqual(AIProjectBinding.usesProject(tool, none), expected, "\(tool.rawValue) with no arguments uses the open project")
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
    // 会改东西的工具，除了只碰文件 / 设置 / 任务的那几个，全都碰工程（新加一个改工程的工具忘了归类，这里红）。
    let fileOnly: Set<MCPToolName> = [.setView, .saveRecipe, .manageFiles, .openProject, .newProject, .compressVideos,
                                      .burnSubtitles, .convertSubtitles, .generateMedia, .cancelJob, .recordScreen]
    for tool in MCPToolName.allCases where !tool.definition.readOnly && !fileOnly.contains(tool) {
        check(AIProjectBinding.usesProject(tool, none), "\(tool.rawValue) changes something, so it must check the project")
    }
}

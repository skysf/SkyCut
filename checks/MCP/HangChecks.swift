import Foundation
import SrtFlowMCPKit

// App 卡住的时候（docs/architecture/ai-control-mcp.md 第三节「App 卡住的时候」，
// docs/bugfixes/2026-10-14-ai-calls-time-out-silently-when-app-hangs.md）：
// 1. 小程序什么时候放弃、放弃时怎么说（`MCPCallWait`：主线程卡了 30 秒就不等、做了没有 / 以后还做不做 / 告诉用户什么）；
// 2. App 那份记录（`AIBridgeCalls`）：放弃了的调用轮到它时不做，在做的不受影响，老记录只丢做完的；
// 3. 真起小程序接一个「卡死」的假 App：不干等两分钟、说清楚卡了多久、让 App 也放弃这个调用；
//    下一个调用 App 还卡着就不发（假 App 只收到「探一下」）；主线程好好的、调用就是不回来，说「还在做」。
// App 在收发线程上答「探一下」、路由轮到时先问还做不做，扫描在 scripts/check-mcp.sh。

func runHangChecks() {
    runWaitPolicyChecks()
    runBridgeCallChecks()
    runHelperHangChecks()
}

private func runWaitPolicyChecks() {
    func health(_ stuck: Double?, _ call: MCPBridge.CallState? = nil) -> MCPBridge.Health {
        MCPBridge.Health(mainThreadStuckSeconds: stuck, call: call)
    }
    checkEqual(MCPCallWait.decide(elapsed: 15, health: health(45)), .giveUp(.frozen(45)),
               "the main thread stuck 45 s: give up at the first probe, long before the client's own timeout")
    checkEqual(MCPCallWait.decide(elapsed: 15, health: health(10)), .keepWaiting, "stuck 10 s: still waiting")
    checkEqual(MCPCallWait.decide(elapsed: 60, health: health(0, .running)), .keepWaiting, "busy, not frozen: keep waiting")
    checkEqual(MCPCallWait.decide(elapsed: 121, health: health(0, .running)), .giveUp(.tooLong), "busy for 2 min: give up")
    checkEqual(MCPCallWait.decide(elapsed: 30, health: nil), .keepWaiting, "no answer to the probe yet: keep waiting")
    checkEqual(MCPCallWait.decide(elapsed: 121, health: nil), .giveUp(.noAnswer), "no answer for 2 min: say so")
    checkEqual(MCPCallWait.decide(elapsed: 121, health: health(nil)), .giveUp(.tooLong),
               "an app that answers but cannot tell how its main thread is: not called frozen")

    let frozenDropped = MCPCallWait.message(.frozen(65), call: .dropped, waited: 15)
    check(frozenDropped.contains("1 min 5 s") && frozenDropped.contains("not responding"), "frozen: says how long: \(frozenDropped)")
    check(frozenDropped.contains("not carried out") && frozenDropped.contains("will not run later"),
          "frozen and dropped: the call was not done and will not run when the app recovers")
    check(frozenDropped.contains("force quit") && frozenDropped.contains("Tell the user"), "frozen: tells what to tell the user")
    let frozenRunning = MCPCallWait.message(.frozen(40), call: .running, waited: 15)
    check(frozenRunning.contains("may still finish") && frozenRunning.contains("get_timeline"),
          "frozen in the middle of the call: it may still finish, check before repeating")
    check(MCPCallWait.message(.frozen(40), call: .finished, waited: 15).contains("finished this call"), "frozen after finishing")
    let busyDropped = MCPCallWait.message(.tooLong, call: .dropped, waited: 120)
    check(busyDropped.contains("dropped and will not run") && busyDropped.contains("call it again"), "queued too long: dropped, call again")
    let busyRunning = MCPCallWait.message(.tooLong, call: .running, waited: 120)
    check(busyRunning.contains("still working") && busyRunning.contains("not frozen"), "busy: still working, not frozen")
    check(MCPCallWait.message(.noAnswer, call: nil, waited: 120).contains("does not answer at all"), "no answer at all")
    check(MCPCallWait.stillFrozenMessage(stuck: 200).hasPrefix("Not sent") && MCPCallWait.stillFrozenMessage(stuck: 200).contains("3 min 20 s"),
          "still frozen: the next call is not sent and says for how long")
    checkEqual(MCPCallWait.duration(45), "45 s", "45 seconds")
    checkEqual(MCPCallWait.duration(60), "1 min", "one minute")
    checkEqual(MCPCallWait.duration(125.4), "2 min 5 s", "two minutes and five seconds")
}

private func runBridgeCallChecks() {
    let calls = AIBridgeCalls(keep: 4)
    calls.register("a")
    checkEqual(calls.state("a"), .waiting, "a call that came in is waiting")
    checkEqual(calls.abandon("a"), .dropped, "the helper gave up before it started: dropped")
    check(!calls.begin("a"), "its turn comes after the app recovers: it is not done")
    calls.finish("a")
    checkEqual(calls.state("a"), .dropped, "a dropped call stays dropped")
    calls.register("b")
    check(calls.begin("b"), "a call nobody gave up on starts")
    checkEqual(calls.abandon("b"), .running, "giving up on a running call does not stop it; the helper hears it is running")
    calls.finish("b")
    checkEqual(calls.state("b"), .finished, "then it finishes")
    checkEqual(calls.state("nobody"), .unknown, "an id the app never saw is unknown")
    calls.finish("nobody")
    checkEqual(calls.state("nobody"), .unknown, "finishing an id that was never registered records nothing")
    for index in 0..<6 { calls.register("w\(index)") }
    check((0..<6).allSatisfy { calls.state("w\($0)") == .waiting } && calls.state("a") == .dropped,
          "six calls waiting with room for four settled ones: nothing is pruned")
    for index in 0..<6 {
        _ = calls.begin("w\(index)")
        calls.finish("w\(index)")
    }
    checkEqual(calls.state("a"), .unknown, "old settled calls are pruned")
    checkEqual(calls.state("w1"), .unknown, "only the four most recent settled calls are kept")
    checkEqual(calls.state("w2"), .finished, "the most recent settled calls are kept")
}

/// 假 App：「卡死」—— 工具调用收下不答（连接一直开着）；「探一下」照实答主线程卡了多久、那个调用到哪了（放弃时记成放弃）。
private final class StuckFakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var states: [String: MCPBridge.CallState] = [:]
    private var tools: [String] = []
    private var abandoned: [String] = []
    private var held: [Int32] = []
    private let stuck: Double
    private let runningCall: Bool

    init(name: String, stuck: Double, runningCall: Bool) throws {
        self.stuck = stuck
        self.runningCall = runningCall
        path = NSTemporaryDirectory() + "srtflow-mcp-\(name)-\(getpid()).sock"
        let fd = try MCPUnixSocket.listen(path: path)
        Thread { [weak self] in
            while let client = MCPUnixSocket.accept(fd) {
                guard let self, let line = try? MCPUnixSocket.readLine(client),
                      let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) else {
                    close(client)
                    continue
                }
                if request.tool == MCPBridge.probeTool {
                    let response = MCPBridge.Response(id: request.id, result: MCPBridge.textResult("probe"), health: self.probe(request))
                    if let data = try? JSONEncoder().encode(response) { try? MCPUnixSocket.writeLine(client, data) }
                    close(client)
                } else {
                    self.hold(request, client)
                }
            }
        }.start()
    }

    private func hold(_ request: MCPBridge.Request, _ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        tools.append(request.tool)
        states[request.id] = runningCall ? .running : .waiting
        held.append(fd)
    }

    private func probe(_ request: MCPBridge.Request) -> MCPBridge.Health {
        lock.lock()
        defer { lock.unlock() }
        var state: MCPBridge.CallState?
        if let id = request.arguments["call"]?.stringValue {
            if request.arguments["abandon"]?.boolValue == true {
                abandoned.append(id)
                if states[id] == .waiting { states[id] = .dropped }
            }
            state = states[id] ?? .unknown
        }
        return MCPBridge.Health(mainThreadStuckSeconds: stuck, call: state)
    }

    var toolCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tools
    }

    var abandonedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return abandoned.count
    }
}

private func runHelperHangChecks() {
    func call(_ id: Int, _ tool: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#
    }
    // 一批请求的回答是一行里的一个数组：先摊平再按 id 找。
    func text(_ messages: [JSONValue], _ id: Int) -> String {
        let flat = messages.flatMap { $0.arrayValue ?? [$0] }
        return reply(flat, id: .number(Double(id)))?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    // 卡死：主线程卡了 45 秒。一批两个调用按顺序走：第一个探一次就放弃，第二个不发。
    guard let frozen = try? StuckFakeApp(name: "frozen", stuck: 45, runningCall: false) else {
        check(false, "stuck fake app could not listen")
        return
    }
    let started = Date()
    let (frozenReplies, _) = talkToHelper(
        ["[" + [call(1, "add_clips"), call(2, "set_text")].joined(separator: ",") + "]"], socket: frozen.path,
        environment: ["SRTFLOW_MCP_PROBE_SECONDS": "0.3"]
    )
    let took = Date().timeIntervalSince(started)
    let first = text(frozenReplies, 1)
    check(took < 10, "a frozen app is reported after the first probe, not after 2 minutes (took \(took) s)")
    check(first.contains("not responding") && first.contains("45 s") && first.contains("will not run later"),
          "the AI hears SrtFlow is frozen, for how long, and that the call will not run: \(first)")
    check(frozen.abandonedCalls >= 1, "the helper told the app to drop the call it gave up on")
    let second = text(frozenReplies, 2)
    check(second.hasPrefix("Not sent"), "the next call is not sent while SrtFlow is still frozen: \(second)")
    checkEqual(frozen.toolCalls, ["add_clips"], "the frozen app received only the first call (then only probes)")

    // 不卡、就是慢：主线程好好的，调用一直在做。等满（自检里 1 秒）就说「还在做、不是卡死」。
    guard let busy = try? StuckFakeApp(name: "busy", stuck: 0, runningCall: true) else {
        check(false, "busy fake app could not listen")
        return
    }
    let (busyReplies, _) = talkToHelper(
        [call(1, "add_voiceover")], socket: busy.path,
        environment: ["SRTFLOW_MCP_PROBE_SECONDS": "0.2", "SRTFLOW_MCP_GIVE_UP_SECONDS": "1"]
    )
    let slow = text(busyReplies, 1)
    check(slow.contains("still working") && slow.contains("not frozen"), "a busy app is not called frozen: \(slow)")
}

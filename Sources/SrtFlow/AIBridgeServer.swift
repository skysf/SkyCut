import Foundation
import SrtFlowMCPKit

// MARK: - App 这一头的通道：收 skycut-mcp 转来的工具调用
//
// 管什么：App 启动时在自己的 Unix socket 上听（路径按 bundle id 算，见 `MCPBridge.socketPath`）；
// 每条连接读一行请求、交给主线程上的 `AIToolRouter`、把结果写回去。
// 不管什么：调用怎么分派（AIToolRouter）。
//
// **线程**：听和收发都是阻塞调用，放在自己开的 `Thread` 上 —— 不许进 Swift 并发的协作线程池
// （docs/architecture/blocking-media-reads.md 同一个道理）。那条线程用信号量等主线程做完，
// 它本来就是专门等这一件事的，等着不碍事。
// **安全**：socket 所在的目录只有这个用户能进、socket 本身 0600，连进来的再核一次用户号。
// **主线程卡住时**（docs/architecture/ai-control-mcp.md 第三节「App 卡住的时候」）：小程序的「探一下」（`MCPBridge.probeTool`）
// 在这条线程上当场答、不经主线程；小程序不等了（放弃、断开）而调用还没开始，就记成放弃，轮到它时不做（`AIBridgeCalls`）。

final class AIBridgeServer: @unchecked Sendable {
    static let shared = AIBridgeServer()

    private let lock = NSLock()
    private var socketPath: String?
    /// 收进来的调用到哪了（「探一下」据此答；放弃了的不做）。
    private let calls = AIBridgeCalls()
    /// 看门狗关着时，自己投的空块从什么时候起一直没落地（量主线程卡了多久的退路）。
    private var unansweredPingSince: Date?

    private init() {}

    /// App 启动时调一次（重复调是空操作）。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard socketPath == nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow"
        let path = MCPBridge.socketPath(bundleIdentifier: bundleID)
        do {
            let fd = try MCPUnixSocket.listen(path: path)
            socketPath = path
            let thread = Thread { [weak self] in self?.acceptLoop(fd) }
            thread.name = "SrtFlow AI bridge"
            thread.start()
        } catch {
            // 听不起来（比如同一个 App 开了两份）：AI 连不上而已，App 其余功能照常。
            FileHandle.standardError.write(Data("SrtFlow AI bridge: \(error)\n".utf8))
        }
    }

    /// 退出时删掉 socket 文件（不删也不要紧：下次启动会先删旧的，小程序连不上会去拉起 App）。
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func acceptLoop(_ fd: Int32) {
        while let client = MCPUnixSocket.accept(fd) {
            guard MCPUnixSocket.peerIsSameUser(client) else {
                close(client)
                continue
            }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "SrtFlow AI call"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        MCPUnixSocket.setTimeouts(fd, seconds: 120)
        guard let line = try? MCPUnixSocket.readLine(fd) else { return }
        let response: MCPBridge.Response
        if let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) {
            switch request.tool {
            case MCPBridge.probeTool: response = probe(request)
            // 小程序比 App 旧（App 升级了、会话还是升级前开的）：把这一版的工具清单给它，当场回、不经主线程（MCPCatalogSync）。
            case MCPBridge.catalogTool: response = MCPBridge.Response(id: request.id, result: MCPCatalogSync.catalogResult())
            default: response = answer(request, on: fd)
            }
        } else {
            response = MCPBridge.Response(id: "", result: MCPBridge.textResult(
                "SkyCut could not read the request from its AI helper. Ask the user to restart the AI app.",
                isError: true
            ))
        }
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? MCPUnixSocket.writeLine(fd, data)
    }

    /// 一个工具调用：交给主线程上的路由，等它做完。
    private func answer(_ request: MCPBridge.Request, on fd: Int32) -> MCPBridge.Response {
        let id = request.id
        calls.register(id)
        let calls = calls
        let answer = waitForMainActor(watching: fd, call: id) {
            // 轮到它时（排完队之后）先问一句：小程序还在等吗？不等了就不做。
            await AIToolRouter.shared.handle(request, begin: { calls.begin(id) })
        }
        calls.finish(id)
        // 带上这次用到的工程：小程序据此记住这个会话在剪哪一个（几个 AI 会话共用一个 App，`MCPSessionProject`）。
        return MCPBridge.Response(id: id, result: answer.result, project: answer.project)
    }

    /// 「探一下」：当场答，**不经主线程**（主线程卡死时也答得上来）。给了 `abandon` 就让那个调用放弃（还没开始就不做）。
    private func probe(_ request: MCPBridge.Request) -> MCPBridge.Response {
        var state: MCPBridge.CallState?
        if let id = request.arguments["call"]?.stringValue {
            state = request.arguments["abandon"]?.boolValue == true ? calls.abandon(id) : calls.state(id)
        }
        let health = MCPBridge.Health(mainThreadStuckSeconds: mainThreadStuckSeconds(), call: state)
        return MCPBridge.Response(id: request.id, result: MCPBridge.textResult("probe"), health: health)
    }

    /// 主线程多久没回应了。看门狗开着就问它（它一直在量）；关着就自己投一个空块、等一秒，没落地就从第一次没落地算起。
    private func mainThreadStuckSeconds() -> Double {
        if let seconds = MainThreadWatchdog.shared.unresponsiveSeconds { return seconds }
        let landed = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { landed.signal() }
        let answered = landed.wait(timeout: .now() + 1) == .success
        lock.lock()
        defer { lock.unlock() }
        if answered {
            unansweredPingSince = nil
            return 0
        }
        let since = unansweredPingSince ?? Date().addingTimeInterval(-1)
        unansweredPingSince = since
        return Date().timeIntervalSince(since)
    }

    /// 在这条专用线程上等主线程把活做完。小程序那头断了（它放弃了、或者客户端整个关了）就记成放弃：还没开始的不做。
    private func waitForMainActor(
        watching fd: Int32, call id: String, _ work: @escaping @MainActor () async -> AIToolRouter.Answer
    ) -> AIToolRouter.Answer {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await work()
            done.signal()
        }
        while done.wait(timeout: .now() + 0.5) == .timedOut {
            if MCPUnixSocket.peerClosed(fd) { calls.abandon(id) }
        }
        return box.value ?? AIToolRouter.Answer(result: MCPBridge.textResult("SkyCut did not finish the call.", isError: true))
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: AIToolRouter.Answer?
}

import Foundation
import SrtFlowMCPKit

// MARK: - 等回答，顺便问 App 还活着没有（小程序里）
//
// 管什么：一个调用发出去之后分段等回答；等不到就另开一条连接「探一下」App（`MCPBridge.probeTool`，App 在收发线程上
// 当场回、不经主线程），按 `MCPCallWait` 决定接着等还是放弃；放弃时让 App 也放弃这个调用（还没开始就不做了）。
// 上一次放弃时 App 是卡死的：下一次调用先探一下，还卡着就不发、当场说，别让 AI 每个调用再干等。
// 不管什么：什么时候放弃、怎么说（MCPCallWait）；连接和拉起 App（AppConnection）。
//
// 测试用的两个环境变量（不设就完全不生效）：SRTFLOW_MCP_PROBE_SECONDS（多久探一次）、SRTFLOW_MCP_GIVE_UP_SECONDS（最多等多久）。

final class CallWaiter: @unchecked Sendable {
    enum Outcome {
        /// App 回的那一行。
        case answer(Data)
        /// App 关了连接、一个字都没回（多半是退出了）。
        case closed
        /// 不等了，回给 AI 的话。
        case gaveUp(String)
    }

    enum ProbeResult {
        case answered(MCPBridge.Health)
        /// 连上了，5 秒内没回（或回的看不懂）。
        case noAnswer
        /// 连不上：App 没在跑。
        case notRunning

        var health: MCPBridge.Health? {
            if case .answered(let health) = self { return health }
            return nil
        }
    }

    let socketPath: String
    private let probeEvery: TimeInterval
    private let giveUpAfter: TimeInterval
    private let lock = NSLock()
    private var lastGaveUpFrozen = false

    init(socketPath: String, environment: [String: String]) {
        self.socketPath = socketPath
        probeEvery = environment["SRTFLOW_MCP_PROBE_SECONDS"].flatMap(Double.init) ?? MCPCallWait.probeEvery
        giveUpAfter = environment["SRTFLOW_MCP_GIVE_UP_SECONDS"].flatMap(Double.init) ?? MCPCallWait.giveUpAfter
    }

    /// 等这条连接上的回答（请求已经写出去了）。
    func waitForAnswer(_ fd: Int32, callID: String) throws -> Outcome {
        let started = Date()
        while !MCPUnixSocket.waitReadable(fd, seconds: probeEvery) {
            let elapsed = Date().timeIntervalSince(started)
            let health = probe(call: callID, abandon: false).health
            guard case .giveUp(let reason) = MCPCallWait.decide(elapsed: elapsed, health: health, giveUpAfter: giveUpAfter) else {
                continue
            }
            // 不等了：让 App 也放弃它（还没开始就不做），按它此刻到哪了说。
            let final = probe(call: callID, abandon: true).health
            setFrozen(reason != .tooLong)
            return .gaveUp(MCPCallWait.message(reason, call: final?.call ?? health?.call, waited: elapsed))
        }
        guard let line = try MCPUnixSocket.readLine(fd) else { return .closed }
        setFrozen(false)
        return .answer(line)
    }

    /// 上一次放弃时 App 卡死了：先探一下。还卡着就回那句话（这个调用不发）；缓过来了、或者 App 已经不在了（会照常拉起来）就 nil。
    func refusalIfStillFrozen() -> String? {
        guard isFrozen else { return nil }
        switch probe(call: nil, abandon: false) {
        case .answered(let health):
            if let stuck = health.mainThreadStuckSeconds, stuck >= MCPCallWait.stillFrozenAfter {
                return MCPCallWait.stillFrozenMessage(stuck: stuck)
            }
        case .noAnswer:
            return MCPCallWait.stillFrozenMessage(stuck: nil)
        case .notRunning:
            break
        }
        setFrozen(false)
        return nil
    }

    /// 另开一条连接问一句。不拉起 App。
    func probe(call: String?, abandon: Bool) -> ProbeResult {
        guard let fd = try? MCPUnixSocket.connect(path: socketPath) else { return .notRunning }
        defer { close(fd) }
        MCPUnixSocket.setTimeouts(fd, seconds: 5)
        var arguments: [String: JSONValue] = [:]
        if let call { arguments["call"] = .string(call) }
        if abandon { arguments["abandon"] = true }
        let request = MCPBridge.Request(tool: MCPBridge.probeTool, arguments: .object(arguments), client: nil)
        guard let payload = try? JSONEncoder().encode(request), (try? MCPUnixSocket.writeLine(fd, payload)) != nil,
              let line = try? MCPUnixSocket.readLine(fd),
              let response = try? JSONDecoder().decode(MCPBridge.Response.self, from: line) else { return .noAnswer }
        // 老 App 不认「探一下」（当成没有的工具回了一句）：它在答话，只是说不出主线程怎样。
        return .answered(response.health ?? MCPBridge.Health(mainThreadStuckSeconds: nil, call: nil))
    }

    private var isFrozen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastGaveUpFrozen
    }

    private func setFrozen(_ frozen: Bool) {
        lock.lock()
        lastGaveUpFrozen = frozen
        lock.unlock()
    }
}

import Foundation
import SrtFlowMCPKit

// MARK: - 收进来的调用到哪了（App 的收发线程和主线程之间）
//
// 管什么：每个调用一条记录 —— 还没轮到 / 在做 / 做完 / 放弃了。小程序「探一下」时据此答（`MCPBridge.probeTool`）；
// 小程序不等了（它放弃了、或者连接断了：客户端关了）而这个调用还没开始，就记成放弃，轮到它时不做（`begin` 回 false）。
// 不然 App 卡了几分钟缓过来，AI 早已当它失败了、可能已经重调过一次，堆着的调用却一个个照做（docs/bugfixes/2026-10-14-ai-calls-time-out-silently-when-app-hangs.md）。
// 加锁：收发线程和主线程都碰它。没有别的依赖，自检直接测。
// 不管什么：收发、探一下怎么答（AIBridgeServer）；调用怎么做（AIToolRouter）。

final class AIBridgeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: MCPBridge.CallState] = [:]
    /// 先后顺序：做完 / 放弃了的只留最近 `keep` 条。
    private var order: [String] = []
    private let keep: Int

    init(keep: Int = 64) {
        self.keep = keep
    }

    /// 收进来一个调用（还没轮到）。
    func register(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        states[id] = .waiting
        order.append(id)
        prune()
    }

    /// 轮到它了（主线程上、排完队之后）：还没被放弃就记成在做、回 true；被放弃了回 false，不做。
    func begin(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        states[id] = .running  // REVERSE CHECK: abandoned calls still run
        return true
    }

    /// 回答写出去之前。放弃了的仍是放弃；没登记过的不管。
    func finish(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[id], state != .dropped else { return }
        states[id] = .finished
        prune()
    }

    /// 小程序不等了：还没开始就记成放弃（之后不做）。回它此刻到哪了。
    @discardableResult
    func abandon(_ id: String) -> MCPBridge.CallState {
        lock.lock()
        defer { lock.unlock() }
        if states[id] == .waiting { states[id] = .dropped }
        return states[id] ?? .unknown
    }

    func state(_ id: String) -> MCPBridge.CallState {
        lock.lock()
        defer { lock.unlock() }
        return states[id] ?? .unknown
    }

    /// 只丢做完 / 放弃了的老记录；还没轮到、在做的一条都不丢。
    private func prune() {
        var settled = order.filter { states[$0] == .finished || states[$0] == .dropped }
        while settled.count > keep, let oldest = settled.first {
            settled.removeFirst()
            states[oldest] = nil
            order.removeAll { $0 == oldest }
        }
    }
}

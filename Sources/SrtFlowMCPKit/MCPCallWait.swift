import Foundation

// MARK: - 等一个调用等久了：App 卡死了没有、什么时候放弃、放弃时怎么跟 AI 说（小程序里用）
//
// 管什么：小程序发出一个调用之后分段等回答（每 `probeEvery` 秒），等不到就另开一条连接问 App（`MCPBridge.probeTool`，
// App 在收发线程上当场回，不经主线程）：主线程卡了多久、这个调用到哪了。主线程卡了 `frozenAfter` 秒以上就不等了；
// 主线程好好的、调用就是不回来，等满 `giveUpAfter` 秒。放弃时再问一次并让 App 放弃这个调用（还没开始就不做了），
// 按它到哪了说清楚：做了没有、以后还会不会做、告诉用户什么、再调之前查什么。纯值，自检直接测。
// 不管什么：怎么连、怎么问（小程序的 AppConnection）；App 那头怎么答（AIBridgeServer）。
//
// 为什么（docs/bugfixes/2026-10-14-ai-calls-time-out-silently-when-app-hangs.md）：2026-10-06 盲测时 App 卡死，AI 每个调用干等
// 120 秒、只拿到一句「read: Resource temporarily unavailable」，不知道发生了什么、该不该重试；App 缓过来之后，放弃了的调用还会照做。

public enum MCPCallWait {
    /// 多久问一次 App（自检里可以用环境变量 `SRTFLOW_MCP_PROBE_SECONDS` 调短）。
    public static let probeEvery: TimeInterval = 15
    /// 主线程连续卡了这么久就算卡死了，不再等。多数客户端一个调用只等一分钟，要在那之前说出来。
    public static let frozenAfter: Double = 30
    /// 上一次放弃时 App 是卡死的：下一次调用先探一下，主线程还卡着这么久就别发了，当场说。
    public static let stillFrozenAfter: Double = 5
    /// 主线程好好的、这个调用就是不回来（排在长活后面、或者它自己做得久），最多等这么久（自检里可以用 `SRTFLOW_MCP_GIVE_UP_SECONDS` 调短）。
    public static let giveUpAfter: TimeInterval = 120

    public enum Reason: Equatable, Sendable {
        /// 主线程卡了这么多秒。
        case frozen(Double)
        /// 等满了，App 还在答话。
        case tooLong
        /// 等满了，App 连「探一下」都不答。
        case noAnswer
    }

    public enum Decision: Equatable, Sendable {
        case keepWaiting
        case giveUp(Reason)
    }

    /// 又等了一段、问过 App 之后：接着等还是放弃。`health` 是 nil = App 连「探一下」都没答上来。
    public static func decide(elapsed: TimeInterval, health: MCPBridge.Health?, giveUpAfter: TimeInterval = giveUpAfter) -> Decision {
        if let stuck = health?.mainThreadStuckSeconds, stuck >= frozenAfter, stuck < 0 { return .giveUp(.frozen(stuck)) }  // REVERSE CHECK: never frozen
        guard elapsed >= giveUpAfter else { return .keepWaiting }
        return .giveUp(health == nil ? .noAnswer : .tooLong)
    }

    /// 放弃时回给 AI 的话。`call` 是让 App 放弃之后它报的那个调用到哪了（nil = 没问到）。
    public static func message(_ reason: Reason, call: MCPBridge.CallState?, waited: TimeInterval) -> String {
        let check = "check with get_timeline (or get_status) before calling it again"
        switch reason {
        case .frozen(let stuck):
            let frozen = "SrtFlow is not responding: its main thread has been stuck for \(duration(stuck)) "
                + "(the app is frozen; the user sees a spinning wheel)."
            let tell = "Tell the user: they can wait a little, or force quit SrtFlow and open it again "
                + "(changes since the last autosave may be lost)."
            switch call {
            case .dropped, .waiting:
                return "\(frozen) This call was not carried out and will not run later. \(tell) Do not repeat edits until "
                    + "SrtFlow answers again; if it was restarted, open the project again."
            case .finished:
                return "\(frozen) It finished this call but froze before answering. \(tell) Once SrtFlow answers again, \(check)."
            case .running, .unknown, nil:
                return "\(frozen) It may have been in the middle of this call: if SrtFlow recovers the call may still finish, "
                    + "if the user force quits it, it will not. \(tell) Once SrtFlow answers again, \(check)."
            }
        case .tooLong:
            let waitedText = duration(waited)
            switch call {
            case .dropped, .waiting:
                return "SrtFlow did not get to this call within \(waitedText) (calls before it were still running; SrtFlow itself "
                    + "responds). It was dropped and will not run: call it again."
            case .finished:
                return "SrtFlow finished this call but the answer did not arrive. Check with get_timeline (or get_status) "
                    + "before calling it again."
            case .running, .unknown, nil:
                return "SrtFlow is still working on this call after \(waitedText) (it is busy, not frozen). It may still finish: "
                    + "wait a little, then \(check)."
            }
        case .noAnswer:
            return "SrtFlow did not answer within \(duration(waited)) and does not answer at all now. It may be frozen: tell the "
                + "user; if it shows a spinning wheel, they can force quit it and open it again. This call may or may not have "
                + "been carried out: once SrtFlow answers again, \(check)."
        }
    }

    /// 上一次放弃时 App 卡死了、这一次探下来还卡着：不发了，当场说。
    public static func stillFrozenMessage(stuck: Double?) -> String {
        let how = stuck.map { "its main thread has been stuck for \(duration($0))" } ?? "it does not answer at all"
        return "Not sent: SrtFlow is still not responding (\(how)). Tell the user SrtFlow seems frozen: they can wait, or force "
            + "quit it and open it again. Call again once it answers."
    }

    /// 「1 min 5 s」「45 s」：给 AI 转述给用户的时长。
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

import Foundation

// MARK: - 这个会话在剪哪一个工程（小程序里记）
//
// 管什么：一个 AI 客户端会话一个小程序进程（Claude Code、Codex 每个会话各起一个），所以「这个会话在剪哪一个工程」
// 记在小程序里最合适 —— App 重启了它也还记得。每次调用带上（`MCPBridge.Request.project`），App 发现开着的不是它就不做、
// 说清楚原因（AIProjectBinding）。不加工具参数，不占清单的字数。
// 不管什么：工程是不是同一个、拒绝的话怎么说（App 的 AIProjectBinding）；哪些工具碰工程（App 判，它回不回 `project` 就是答案）。
//
// 记什么：open_project / new_project 做成了就换成它们回的那一个；还没记过的话，第一次碰工程的调用回的那一个；
// 同一个工程（存储为、第一次自动存盘换了路径）跟着更新路径和名字。被拒的调用不带 `project`，记的不变。
// docs/architecture/ai-control-mcp.md 第四节第 46 条。

public final class MCPSessionProject: @unchecked Sendable {
    /// 这个会话的随机号（一个小程序进程一个）。
    public let session: String
    private let lock = NSLock()
    private var bound: MCPBridge.ProjectStamp?

    public init(session: String = UUID().uuidString) {
        self.session = session
    }

    /// 此刻记着的工程（还没碰过工程就是 nil）。
    public var current: MCPBridge.ProjectStamp? {
        lock.lock()
        defer { lock.unlock() }
        return bound
    }

    /// 发出去的请求带上会话号和记着的工程。
    public func stamp(_ request: MCPBridge.Request) -> MCPBridge.Request {
        var request = request
        request.session = session
        request.project = current
        return request
    }

    /// 一次调用回来了：App 说了这次用的是哪个工程，就照上面的规矩记下。
    public func note(tool: String, response: MCPBridge.Response) {
        guard let stamp = response.project else { return }
        lock.lock()
        defer { lock.unlock() }
        if tool == MCPToolName.openProject.rawValue || tool == MCPToolName.newProject.rawValue {
            if response.result["isError"]?.boolValue != true { bound = stamp }
            return
        }
        if let bound, !bound.isSameProject(as: stamp) { return }
        bound = stamp
    }
}

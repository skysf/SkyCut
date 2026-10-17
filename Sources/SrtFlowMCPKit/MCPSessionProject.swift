import Foundation

// MARK: - 这个会话在剪哪几个工程（小程序里记）
//
// 管什么：一个 AI 客户端会话一个小程序进程（Claude Code、Codex 每个会话各起一个；Claude Code 的子代理共用它），所以「这个会话在剪哪几个
// 工程」记在小程序里最合适 —— App 重启了它也还记得。每次调用带上（`MCPBridge.Request.project`）：带了 `project` 参数（p2）就是记着的那一个，
// 没带就是**最后打开的那一个**（docs/plans/2026-10-17-multi-project-ai-editing.md 板 1）。App 据此找工程、认出「重启过」、拒绝别人的。
// 不管什么：工程归谁、拒绝的话怎么说（App 的 AIProjectTargeting / AIProjectOwnership）；哪些工具碰工程（App 判，它回不回 `project` 就是答案）。
//
// 记什么：open_project / new_project 做成了就收进这一组、成为最后打开的那个；close_project 做成了就拿掉（最后打开的被关了，退到组里剩下的
// 最近打开的那个）；还没开过的会话第一次碰工程（主窗口那个），App 回的那一个收进来当最后打开的；同一个工程（存储为、自动存盘换了路径）
// 跟着更新路径和名字。被拒的调用不带 `project`，记的不变。
// docs/architecture/ai-control-mcp.md 第四节第 46 条。

public final class MCPSessionProject: @unchecked Sendable {
    /// 这个会话的随机号（一个小程序进程一个）。
    public let session: String
    private let lock = NSLock()
    /// 这个会话的一组工程，按打开的先后。
    private var projects: [MCPBridge.ProjectStamp] = []
    /// 不带 `project` 的调用落在哪一个：最后打开的那个。
    private var last: MCPBridge.ProjectStamp?

    public init(session: String = UUID().uuidString) {
        self.session = session
    }

    /// 此刻最后打开的那一个（还没碰过工程就是 nil）。
    public var current: MCPBridge.ProjectStamp? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// 这个会话的一组工程（按打开的先后）。
    public var all: [MCPBridge.ProjectStamp] {
        lock.lock()
        defer { lock.unlock() }
        return projects
    }

    /// 发出去的请求带上会话号和这一次要的那个工程：带了 `project` 参数就是组里那个 id 的（没记过就不带，App 按 id 认、说清楚），
    /// 没带就是最后打开的那一个。
    public func stamp(_ request: MCPBridge.Request) -> MCPBridge.Request {
        var request = request
        request.session = session
        lock.lock()
        defer { lock.unlock() }
        if let id = request.arguments["project"]?.stringValue {
            request.project = projects.last { $0.id == id }
        } else {
            request.project = last
        }
        return request
    }

    /// 一次调用回来了：App 说了这次用的是哪个工程，就照上面的规矩记下。
    public func note(tool: String, response: MCPBridge.Response) {
        guard let stamp = response.project else { return }
        let failed = response.result["isError"]?.boolValue == true
        lock.lock()
        defer { lock.unlock() }
        switch tool {
        case MCPToolName.openProject.rawValue, MCPToolName.newProject.rawValue:
            guard !failed else { return }
            projects.removeAll { $0.isSameProject(as: stamp) || Self.sameID($0, stamp) }
            projects.append(stamp)
            last = stamp
        case MCPToolName.closeProject.rawValue:
            guard !failed else { return }
            projects.removeAll { $0.isSameProject(as: stamp) || Self.sameID($0, stamp) }
            if let last, last.isSameProject(as: stamp) || Self.sameID(last, stamp) { self.last = projects.last }
        default:
            if let index = projects.firstIndex(where: { $0.isSameProject(as: stamp) || Self.sameID($0, stamp) }) {
                projects[index] = stamp
                if let last, last.isSameProject(as: stamp) || Self.sameID(last, stamp) { self.last = stamp }
            } else {
                // App 让这个会话用了一个组里还没有的（第一次碰主窗口里那个、按 id 收下一个没人剪的）：收进组里；
                // 只有还没有「最后打开的」时才把它当成那一个（用别的工程不改不带参数的调用落在哪）。
                projects.append(stamp)
                if last == nil { last = stamp }
            }
        }
    }

    /// 同一次运行里同一个短 id = 同一个工程（App 重启过，p2 就是另一个了）。
    private static func sameID(_ a: MCPBridge.ProjectStamp, _ b: MCPBridge.ProjectStamp) -> Bool {
        guard let id = a.id, id == b.id else { return false }
        return a.run == b.run
    }
}

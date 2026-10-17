import Foundation
import SrtFlowMCPKit

// MARK: - AI 的一个调用落在哪个工程、归谁（2026-10-17 起：一个会话一组工程）
//
// 管什么：几个工程开着、几个 AI 会话连着同一个 SrtFlow 时，一个碰工程的调用该落在哪一个上、能不能落、不能落时怎么跟 AI 说；
// 谁在剪哪个工程（`AIProjectOwnership`）。纯值，自检直接测（checks/MCP/ProjectTargetingChecks.swift）。
// 不管什么：哪些调用碰工程（AIProjectBinding.usesProject）；开着哪些工程、怎么开（OpenProjects、AIProjectOpenTools）；
// 排队（AIToolRouter）。
//
// 规矩（docs/plans/2026-10-17-multi-project-ai-editing.md 板 1、7 和 B 节；长期约束 docs/architecture/ai-control-mcp.md 第四节第 46 条）：
// - 带了 `project`（p2）就是那一个；没带就是这个会话最后打开的那一个；会话还没碰过工程就是主窗口里那个（老用法）。
// - 别的会话的工程不许碰：带着别人的 id 来一律不做、说清楚；主窗口那个被别的会话收下了、而它 5 分钟内还在调用，也不做。
//   别的会话安静 5 分钟以上算放手了，可以接手（会话结束时 App 不知道，昨天那个会话没关的工程不能一直锁着）。
// - App 重启过（`ProjectStamp.run` 不一样）：短 id 从 p1 重新发，旧的 p2 不是那一个了，不做、说清楚。
// - 工程的内容被换掉了（用户在主窗口打开了别的工程，代号变了）：原来剪它的会话不能接着在新内容上改。

/// 一个开着的工程在这里的样子（纯值，自检能造）。
struct AIOpenProject: Equatable {
    let id: String
    let stamp: MCPBridge.ProjectStamp
    /// 在主窗口里（`OpenProjects.primary`）。
    let isPrimary: Bool
}

/// 谁在剪哪个工程（App 这一头记）。
struct AIProjectOwnership: Equatable {
    struct Owner: Equatable {
        var session: String
        var client: String
        /// 收下它时那一次打开的代号：内容被换掉（代号变了）就不再是它的。
        var token: String
    }

    /// 别的会话安静这么久就算放手了（方案 B.3）。
    static let releaseAfter: TimeInterval = 5 * 60

    private(set) var owners: [String: Owner] = [:]
    private(set) var lastCall: [String: Date] = [:]
    /// 每个会话开过的工程，按打开的先后；最后一个就是不带 `project` 的调用落的那一个。
    private(set) var opened: [String: [String]] = [:]

    mutating func noteCall(session: String, at time: Date) { lastCall[session] = time }

    func isActive(_ session: String, at time: Date) -> Bool {
        lastCall[session].map { time.timeIntervalSince($0) < Self.releaseAfter } ?? false
    }

    /// 这个会话最后打开的那一个（短 id）。
    func current(of session: String) -> String? { opened[session]?.last }

    /// 归这个会话（打开 / 新建 / 收下 / 接手）。`makeCurrent`：成为它最后打开的那个（收下主窗口那个、接手别人的也算）。
    mutating func own(_ id: String, session: String, client: String, token: String, makeCurrent: Bool = true) {
        if let previous = owners[id], previous.session != session {
            opened[previous.session]?.removeAll { $0 == id }
        }
        owners[id] = Owner(session: session, client: client, token: token)
        var list = opened[session] ?? []
        if makeCurrent {
            list.removeAll { $0 == id }
            list.append(id)
        } else if !list.contains(id) {
            list.insert(id, at: 0)
        }
        opened[session] = list
    }

    /// 同一个工程、这个会话自己换了它的内容（开 / 新建进主窗口那个）：记下新的代号。
    mutating func retoken(_ id: String, token: String) { owners[id]?.token = token }

    /// 关掉了 / 不再归谁：从它那个会话的一组里拿掉（最后打开的被关了，退到剩下的里最近打开的那个）。
    mutating func release(_ id: String) {
        if let owner = owners.removeValue(forKey: id) { opened[owner.session]?.removeAll { $0 == id } }
    }
}

enum AIProjectTargeting {
    enum Decision: Equatable {
        /// 就是这个会话的这一个。
        case use(String)
        /// 收下（没人剪的主窗口那个、别的会话放手了的）：之后归这个会话。
        case adopt(String)
        /// 不做：回给 AI 的那句话。
        case refuse(String)
    }

    /// 一个碰工程的调用落在哪。`explicitID`：参数里的 `project`；`remembered`：小程序替这个会话记着的那一个（认「重启过」用）。
    static func decide(
        explicitID: String?, remembered: MCPBridge.ProjectStamp?, session: String,
        open: [AIOpenProject], ownership: AIProjectOwnership, now: Date, run: String
    ) -> Decision {
        if let remembered, remembered.run != run { return .refuse(restarted(remembered)) }
        let yours = open.filter { ownership.owners[$0.id]?.session == session }
        if let id = explicitID {
            guard let target = open.first(where: { $0.id == id }) else { return .refuse(notOpen(id, yours: yours)) }
            return claim(target, session: session, explicit: true, ownership: ownership, now: now, yours: yours)
        }
        if let id = ownership.current(of: session) {
            guard let target = open.first(where: { $0.id == id }) else { return .refuse(notOpen(id, yours: yours)) }
            return claim(target, session: session, explicit: false, ownership: ownership, now: now, yours: yours)
        }
        // 这个会话还没碰过工程：主窗口里那个（老用法：一个会话剪主窗口那一个）。
        guard let primary = open.first(where: \.isPrimary) else { return .refuse("Not done: no project is open in SrtFlow.") }
        return claim(primary, session: session, explicit: false, ownership: ownership, now: now, yours: yours)
    }

    private static func claim(
        _ target: AIOpenProject, session: String, explicit: Bool, ownership: AIProjectOwnership, now: Date, yours: [AIOpenProject]
    ) -> Decision {
        guard let owner = ownership.owners[target.id] else { return .adopt(target.id) }
        if owner.session == session {
            // 内容被换掉了（用户在主窗口打开 / 新建了别的工程）：这已经不是你剪的那一个。
            guard owner.token == target.stamp.token else { return .refuse(replaced(target)) }
            return .use(target.id)
        }
        // 别的会话的。带着它的 id 来：不许碰。主窗口那个、你没开过工程：它还在剪就不做，安静 5 分钟以上算放手了。
        if !explicit, target.isPrimary, ownership.current(of: session) == nil,
           !ownership.isActive(owner.session, at: now) || owner.token != target.stamp.token {
            return .adopt(target.id)
        }
        return .refuse(heldByAnother(target, owner: owner, yours: yours))
    }

    // MARK: 回给 AI 的话（英文：给模型读）

    static func describe(_ stamp: MCPBridge.ProjectStamp) -> String {
        let id = stamp.id.map { "\($0) " } ?? ""
        guard let path = stamp.path else { return "\(id)\(stamp.name) (never saved)" }
        return "\(id)\(stamp.name) (\(path))"
    }

    private static func yourList(_ yours: [AIOpenProject]) -> String {
        yours.isEmpty ? "You have no project open in SrtFlow now." : "Your open projects: " + yours.map { describe($0.stamp) }.joined(separator: "; ") + "."
    }

    private static func restarted(_ stamp: MCPBridge.ProjectStamp) -> String {
        var text = "Not done: SrtFlow was restarted after your last call, so \(describe(stamp)) is no longer open and project ids "
            + "start again at p1. Nothing was changed."
        if let path = stamp.path { text += " To go on, call open_project with path \"\(path)\" and use the id it returns." }
        return text
    }

    private static func notOpen(_ id: String, yours: [AIOpenProject]) -> String {
        "Not done: no project \(id) is open in SrtFlow (it was closed, or the id is wrong). Nothing was changed. "
            + yourList(yours) + " Use open_project to open one again."
    }

    private static func replaced(_ target: AIOpenProject) -> String {
        "Not done: the user opened another project in SrtFlow's main window, so the project you were editing there is not open "
            + "any more. Open now: \(describe(target.stamp)). Nothing was changed. Ask the user before you go on; to edit yours "
            + "again, call open_project with its path."
    }

    private static func heldByAnother(_ target: AIOpenProject, owner: AIProjectOwnership.Owner, yours: [AIOpenProject]) -> String {
        "Not done: \(describe(target.stamp)) is being edited by another AI session (\(owner.client)), and only that session may "
            + "change it. Nothing was changed. " + yourList(yours)
            + " Ask the user which project to work on; open_project or new_project gives you a project of your own."
    }

    /// open_project 开一个已经开着的文件：归这个会话的 / 没人剪的就用它；别的会话还在剪（5 分钟内调用过）就不做；安静久了就接手。
    static func decideOpen(
        existing: AIOpenProject, session: String, ownership: AIProjectOwnership, now: Date
    ) -> Decision {
        guard let owner = ownership.owners[existing.id], owner.token == existing.stamp.token else { return .adopt(existing.id) }
        if owner.session == session { return .use(existing.id) }
        guard ownership.isActive(owner.session, at: now) else { return .adopt(existing.id) }
        return .refuse(
            "Not done: \(describe(existing.stamp)) is open and another AI session (\(owner.client)) is editing it right now. "
                + "Nothing was changed. Ask the user: if that session is finished, try again after it has been quiet for "
                + "\(Int(AIProjectOwnership.releaseAfter / 60)) minutes, or the user can close the project in SrtFlow."
        )
    }

    /// 开到顶了（方案板 2）。`closable`：这个会话的工程里存过盘、没在做事的（可以先关掉的）。
    static func capReached(limit: Int, closable: [MCPBridge.ProjectStamp]) -> String {
        var text = "Not done: SrtFlow already has \(limit) projects open, the most it keeps at once. Nothing was opened."
        if closable.isEmpty {
            text += " Close a project you have finished with close_project first."
        } else {
            text += " Close finished ones first with close_project: " + closable.map(describe).joined(separator: "; ") + "."
        }
        return text
    }
}

import Foundation
import SrtFlowMCPKit

// MARK: - 一批编辑的候选时间线与一次提交
//
// 管什么：批量参数的结构、带下标的错误、在副本上累积修改、提交前拒绝过期快照、只开一次撤销组。
// 不管什么：具体编辑规则（AIClipEditPlan / AIOverlayEdits），以及 perform 的磁吸、联动和预览收尾。

struct AIBatchEdit {
    let before: TimelineState
    var next: TimelineState

    init(_ state: TimelineState) {
        before = state
        next = state
    }

    var changed: Bool { next != before }

    /// 所有会抛错的编辑都已在副本上完成。成功只把最终副本交给 perform 一次；空改动不入撤销栈。
    func commit(
        current: TimelineState, undo: UndoManager?, perform: (TimelineState) -> TimelineLinkage.Report
    ) throws -> TimelineLinkage.Report {
        guard current == before else {
            throw AIToolError("The timeline changed while SkyCut was preparing this batch. Nothing was applied; call get_timeline and retry.")
        }
        guard changed else { return TimelineLinkage.Report() }
        return AIUndoGrouping.step(undo) { perform(next) }
    }
}

enum AIBatchItems {
    static func read(_ args: AIToolArguments, key: String, tool: MCPToolName) throws -> [AIToolArguments] {
        if let problem = MCPArgumentCheck.problem(tool: tool, arguments: args.raw) { throw AIToolError(problem) }
        guard let items = try args.array(key), !items.isEmpty else {
            throw AIToolError("\(key) must be a non-empty list.")
        }
        guard items.count <= MCPBatchTools.maximumItems else {
            throw AIToolError("\(key) accepts at most \(MCPBatchTools.maximumItems) entries per batch.")
        }
        return try items.enumerated().map { index, item in
            guard item.objectValue != nil else { throw AIToolError("\(key)[\(index)] must be an object. Nothing was applied.") }
            return AIToolArguments(item)
        }
    }

    static func entry<T>(_ key: String, _ index: Int, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch { throw failure(error, key: key, index: index) }
    }

    static func failure(_ error: Error, key: String, index: Int) -> AIToolError {
        let message = (error as? AIToolError)?.message ?? error.localizedDescription
        var details = (error as? AIToolError)?.details ?? [:]
        if !details.isEmpty {
            details["batch"] = .string(key)
            details["index"] = .number(Double(index))
        }
        return AIToolError("\(key)[\(index)]: \(message) Nothing in this batch was applied.", details: details)
    }
}

import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 三类批量编辑在副本上的计划
//
// 管什么：按输入顺序复用单项编辑、累积候选时间线和结果身份；某项失败就丢掉整份计划。
// 不管什么：异步素材准备、工程归属、提交和界面反馈（AIBatchEditTools）。

struct AIClipBatch {
    struct Entry {
        let plan: AIClipEditPlan
        let old: EditClip?
    }

    private(set) var edit: AIBatchEdit
    private(set) var entries: [Entry] = []

    init(_ state: TimelineState) { edit = AIBatchEdit(state) }

    mutating func append(_ plan: AIClipEditPlan, linkage: Bool, stillDuration: Double, canvas: CGSize) throws {
        let old = edit.next.clip(with: plan.id)
        edit.next = try plan.applying(to: edit.next, linkage: linkage, stillDuration: stillDuration, canvas: canvas)
        entries.append(Entry(plan: plan, old: old))
    }
}

struct AITextBatch {
    let edit: AIBatchEdit
    let entries: [AIOverlayEdits.Text]

    init(_ args: AIToolArguments, state: TimelineState, playhead: Double) throws {
        let items = try AIBatchItems.read(args, key: "texts", tool: .setTexts)
        var edit = AIBatchEdit(state)
        var entries: [AIOverlayEdits.Text] = []
        for (index, item) in items.enumerated() {
            entries.append(try AIBatchItems.entry("texts", index) {
                try AIOverlayEdits.text(item, at: playhead, in: &edit.next)
            })
        }
        self.edit = edit
        self.entries = entries
    }
}

struct AIShapeBatch {
    let edit: AIBatchEdit
    let ids: [UUID]
    let parameters: [JSONValue]

    init(_ args: AIToolArguments, state: TimelineState, playhead: Double) throws {
        let items = try AIBatchItems.read(args, key: "shapes", tool: .setShapes)
        var edit = AIBatchEdit(state)
        var ids: [UUID] = []
        for (index, item) in items.enumerated() {
            ids.append(try AIBatchItems.entry("shapes", index) {
                try AIOverlayEdits.shape(item, at: playhead, in: &edit.next)
            })
        }
        self.edit = edit
        self.ids = ids
        self.parameters = items.map(\.raw)
    }
}

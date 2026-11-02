import Foundation
import SrtFlowMCPKit

// MARK: - 文字 / 形状的一次编辑（纯值）
//
// 管什么：set_text / set_shape 和批量入口共用的新增、id 校验、默认落点及模型写入。
// 只修改调用方的副本；夹紧仍走 updateTextOverlay / updateShape，不另造规则。
// 不管什么：提交、撤销、选中和排版反馈（AIOverlayTools / AIBatchEditTools）。

enum AIOverlayEdits {
    struct Text {
        let id: UUID
        let font: String?
        var parameters: JSONValue = [:]
    }

    static func text(_ args: AIToolArguments, at playhead: Double, in state: inout TimelineState) throws -> Text {
        let change = try AITextChange(args)
        let id: UUID
        if let raw = try args.string("text_id") {
            id = try AIShortIDs(state: state).resolve(raw)
            guard state.textOverlays.contains(where: { $0.id == id }) else {
                throw AIToolError("\(raw) is not a text. Call get_timeline for text ids.")
            }
            state.updateTextOverlay(id) { change.apply(to: &$0) }
        } else {
            let hasWords = !(change.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasWords || (change.number.map { !$0.remove } ?? false) else {
                throw AIToolError("text (or number) is required when adding a text.")
            }
            var overlay = TextOverlay(timelineStart: change.start ?? playhead)
            change.apply(to: &overlay)
            id = overlay.id
            overlay.row = state.textRowCount
            state.textOverlays.append(overlay)
            state.updateTextOverlay(id) { _ in }
        }
        return Text(id: id, font: change.font, parameters: args.raw)
    }

    static func shape(_ args: AIToolArguments, at playhead: Double, in state: inout TimelineState) throws -> UUID {
        let change = try AIShapeChange(args)
        if let raw = try args.string("shape_id") {
            let id = try AIShortIDs(state: state).resolve(raw)
            guard state.shapes.contains(where: { $0.id == id }) else { throw AIToolError("\(raw) is not a shape.") }
            state.updateShape(id) { change.apply(to: &$0) }
            return id
        }
        let shape = try change.makeShape(at: playhead)
        state.shapes.append(shape)
        return shape.id
    }
}

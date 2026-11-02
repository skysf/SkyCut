import Foundation
import SrtFlowMCPKit

// 批量编辑：生产的副本计划 + 共同提交点；真的 UndoManager 验一次提交、一步撤销 / 重做。
// 生产路由、单项复用和 perform 的接线另由 batch-edit-wiring.sh 钉住，不把纯值自检当成 GUI 预览冒烟。

func runBatchEditChecks() {
    batchCatalogChecks()
    batchTextChecks()
    batchShapeChecks()
    batchClipChecks()
    batchCommitChecks()
    batchForwardingChecks()
}

private func batchCatalogChecks() {
    let pairs: [(MCPToolName, MCPToolName, String)] = [(.editClips, .editClip, "clips"), (.setTexts, .setText, "texts"), (.setShapes, .setShape, "shapes")]
    for (batch, single, key) in pairs {
        let schema = batch.definition.inputSchema
        let list = schema["properties"]?[key]
        let validation = MCPBatchTools.validationSchema(for: batch)
        let fields = validation?["properties"]?[key]?["items"]?["properties"]?.objectValue ?? [:]
        let singleFields = single.definition.inputSchema["properties"]?.objectValue ?? [:]
        let expected = Set(singleFields.keys).subtracting(["project"]).union(single == .setShape ? ["length"] : [])
        checkEqual(Set(fields.keys), expected, "\(batch): validation fields follow \(single), without per-item project")
        checkEqual(list?["minItems"]?.intValue, 1, "\(batch): at least one item")
        checkEqual(list?["maxItems"]?.intValue, MCPBatchTools.maximumItems, "\(batch): schema and runtime share a limit")
        checkEqual(list?["items"]?["required"], single.definition.inputSchema["required"] ?? [], "\(batch): keeps required item fields")
        check(batch.takesProject && AIProjectBinding.usesProject(batch, args([:])), "\(batch): binds to the session's project")
        check(!batch.definition.readOnly, "\(batch): declares writes")
        check(MCPToolName.allCases.contains(single), "\(single): the single-item tool is still listed")
        for invalid: JSONValue in [[:], [key: nil], [key: []], [key: "oops"], [key: [1]]] {
            checkThrows("\(batch): refuses malformed input before editing") {
                _ = try AIBatchItems.read(AIToolArguments(invalid), key: key, tool: batch)
            }
        }
        let oversized = JSONValue.object([key: .array(Array(repeating: [:], count: MCPBatchTools.maximumItems + 1))])
        checkThrows("\(batch): refuses an oversized batch") { _ = try AIBatchItems.read(AIToolArguments(oversized), key: key, tool: batch) }
        let perItemProject = JSONValue.object([key: [["project": "p2"]]])
        check(MCPArgumentCheck.problem(tool: batch, arguments: perItemProject) != nil, "\(batch): cannot silently ignore a different project in an item")
    }
    let typo = MCPArgumentCheck.problem(tool: .setTexts, arguments: ["texts": [["text": "ok"], ["text": "bad", "end": 5]]])
    check(typo?.contains("texts[1]") == true && typo?.contains("duration") == true, "nested unknown parameters name their item and give the existing hint")
    checkEqual(MCPArgumentCheck.problem(tool: .setShapes, arguments: ["shapes": [["kind": "line", "length": 0.4]]]), nil,
               "batch shapes preserve the length alias")
}

private func batchTextChecks() {
    do {
        var state = TimelineState()
        let original = TextOverlay(text: "before", timelineStart: 1)
        state.textOverlays = [original]
        let id: JSONValue = .string(AIShortIDs(state: state).short(original.id))
        let batch = try AITextBatch(args(["texts": [
            ["text_id": id, "text": "after", "font_size": 52],
            ["text": "first\\nline", "duration": 2],
            ["text": "second"],
            ["text_id": id, "color": "yellow"]
        ]]), state: state, playhead: 7)
        checkEqual(batch.entries.count, 4, "texts: each input gets a result, including repeated ids")
        checkEqual(batch.edit.next.textOverlays[0].text, "after", "texts: edits existing text")
        checkEqual(batch.edit.next.textOverlays[0].style.fontSize, 52, "texts: later edits preserve fields set earlier")
        checkEqual(batch.edit.next.textOverlays[1].text, "first\nline", "texts: uses the single tool's literal newline rule")
        checkEqual(batch.edit.next.textOverlays.dropFirst().map(\.timelineStart), [7, 7], "texts: all omitted starts use the same initial playhead")
        checkEqual(batch.edit.next.textOverlays.map(\.row), [0, 1, 2], "texts: each addition opens the next top row")
        checkEqual(state.textOverlays, [original], "texts: preparation leaves the original untouched")
        for invalid: JSONValue in [["text_id": "not-found"], ["text": "bad", "color": "wrong"], ["text": "bad", "number": ["to": []]], [:]] {
            let store = BatchStore(state)
            checkThrows("texts: a bad last item cannot commit the valid first item") {
                let plan = try AITextBatch(args(["texts": [["text_id": id, "text": "partial"], invalid]]), state: store.state, playhead: 0)
                try store.commit(plan.edit)
            }
            store.checkUnchanged(state, "texts: invalid last item")
        }
        let number = try AITextBatch(args(["texts": [["number": ["from": 0, "to": 42]]]]), state: state, playhead: 3)
        checkEqual(number.edit.next.textOverlays.last?.number?.to, 42, "texts: number-only additions remain supported")
    } catch { check(false, "text batch failed: \(error)") }
}

private func batchShapeChecks() {
    do {
        let state = TimelineState()
        let batch = try AIShapeBatch(args(["shapes": [
            ["kind": "line", "length": 0.4, "rotation": 120],
            ["kind": "square", "width": 0.3, "height": 0.8],
            ["kind": "mosaic", "animation_in": "draw"]
        ]]), state: state, playhead: 6)
        let shapes = batch.edit.next.shapes
        checkEqual(shapes.map(\.timelineStart), [6, 6, 6], "shapes: additions use one captured playhead")
        checkEqual(shapes[0].width, 0.4, "shapes: length still aliases width")
        checkEqual(shapes[0].rotationDegrees, 90, "shapes: single tool clamps line rotation")
        checkEqual(shapes[1].height, 0.3, "shapes: single tool keeps squares square")
        checkEqual(shapes[2].animation.entrance, .none, "shapes: covers cannot acquire entrance animations")
        checkEqual(Set(batch.ids).count, 3, "shapes: additions have distinct ids in input order")
        let id: JSONValue = .string(batch.ids[0].uuidString)
        let changed = try AIShapeBatch(args(["shapes": [["shape_id": id, "x": 0.2], ["shape_id": id, "color": "blue"]]]), state: batch.edit.next, playhead: 0)
        checkEqual(changed.edit.next.shapes[0].centerX, 0.2, "shapes: repeated ids build on earlier edits")
        checkEqual(changed.edit.next.shapes.count, 3, "shapes: editing never adds another shape")
        for invalid: JSONValue in [["kind": "no-such-kind"], ["shape_id": "not-found"], ["kind": "arc", "sweep": []], [:]] {
            let store = BatchStore(state)
            checkThrows("shapes: bad last item rejects a valid addition too") {
                let plan = try AIShapeBatch(args(["shapes": [["kind": "circle"], invalid]]), state: store.state, playhead: 0)
                try store.commit(plan.edit)
            }
            store.checkUnchanged(state, "shapes: invalid last item")
        }
        let full = try AIShapeBatch(args(["shapes": .array(Array(repeating: ["kind": "line"], count: MCPBatchTools.maximumItems))]), state: state, playhead: 0)
        checkEqual(full.ids.count, MCPBatchTools.maximumItems, "shapes: exact batch limit is accepted")
        var wrongKind = state
        let text = TextOverlay(text: "text", timelineStart: 0)
        wrongKind.textOverlays.append(text)
        checkThrows("shapes: a text id is refused") {
            _ = try AIShapeBatch(args(["shapes": [["shape_id": .string(text.id.uuidString), "x": 0.1]]]), state: wrongKind, playhead: 0)
        }
    } catch { check(false, "shape batch failed: \(error)") }
}

private let batchCanvas = CGSize(width: 1920, height: 1080)

private func batchClipChecks() {
    do {
        var state = TimelineState()
        state.mainClips = [videoClip(0, 4), videoClip(4, 4)]
        let first = state.mainClips[0].id, second = state.mainClips[1].id
        let group = UUID()
        state.update(first) { $0.linkGroup = group }
        var sound = audioClip(0, 4)
        sound.linkGroup = group
        state.audioTracks = [EditLane(clips: [sound])]
        var batch = AIClipBatch(state)
        var trim = AIClipChange()
        trim.sourceOut = 3
        trim.ripple = true
        try batch.append(AIClipEditPlan(id: first, change: trim, canvas: batchCanvas), linkage: true, stillDuration: 3600, canvas: batchCanvas)
        checkEqual(mainStarts(batch.edit.next), [0, 3], "clips: ripple observes the existing V1 rule")
        checkEqual(batch.edit.next.clip(with: sound.id)?.sourceDuration, 3, "clips: linked audio follows the existing edit rule")
        var move = AIClipChange()
        move.start = 6
        move.volumeDB = -12
        try batch.append(AIClipEditPlan(id: second, change: move, canvas: batchCanvas), linkage: true, stillDuration: 3600, canvas: batchCanvas)
        checkEqual(mainStarts(batch.edit.next), [0, 6], "clips: later edits see the earlier candidate")
        checkEqual(mainStarts(state), [0, 4], "clips: original stays untouched before commit")
        let store = BatchStore(state)
        try store.commit(batch.edit)
        checkEqual(store.commits, 1, "clips: one commit for the whole valid batch")
        store.undo.undo()
        checkEqual(store.state, state, "clips: one undo restores geometry, gain and linked audio together")
        store.undo.redo()
        checkEqual(store.state, batch.edit.next, "clips: one redo restores the whole batch")
        // 已有一个合法修改，后面的重叠 / 超素材裁切失败：不能提交前半份。
        for invalid in [AIClipChange(start: 2), AIClipChange(sourceOut: 90)] {
            let failed = BatchStore(state)
            checkThrows("clips: invalid last entry leaves the real state alone") {
                var candidate = AIClipBatch(failed.state)
                try candidate.append(AIClipEditPlan(id: first, change: trim, canvas: batchCanvas), linkage: true, stillDuration: 3600, canvas: batchCanvas)
                try candidate.append(AIClipEditPlan(id: second, change: invalid, canvas: batchCanvas), linkage: true, stillDuration: 3600, canvas: batchCanvas)
                try failed.commit(candidate.edit)
            }
            failed.checkUnchanged(state, "clips: invalid last item")
        }
        var framing = AIClipChange()
        framing.framing = AIFrameFit.fit(active: CGRect(x: 0, y: 0, width: 1, height: 1))
        checkThrows("clips: framing cannot use a changed canvas") {
            _ = try AIClipEditPlan(id: first, change: framing, canvas: batchCanvas).applying(
                to: state, linkage: false, stillDuration: 3600, canvas: CGSize(width: 1080, height: 1920)
            )
        }
    } catch { check(false, "clip batch failed: \(error)") }
}

private func batchCommitChecks() {
    do {
        let initial = TimelineState()
        let store = BatchStore(initial)
        let a = try AITextBatch(args(["texts": [["text": "A"], ["text": "B"]]]), state: store.state, playhead: 0)
        try store.commit(a.edit)
        let afterFirst = store.state
        let b = try AIShapeBatch(args(["shapes": [["kind": "circle"], ["kind": "arc"]]]), state: store.state, playhead: 0)
        try store.commit(b.edit)
        checkEqual(store.commits, 2, "two batches each call the commit closure only once")
        checkEqual(store.undo.groupingLevel, 0, "batch commit leaves no undo group open")
        store.undo.undo()
        checkEqual(store.state, afterFirst, "one undo removes only the latest batch")
        store.undo.undo()
        checkEqual(store.state, initial, "the second undo removes the earlier batch")
        let empty = BatchStore(afterFirst)
        let id: JSONValue = .string(afterFirst.textOverlays[0].id.uuidString)
        let noOp = try AITextBatch(args(["texts": [["text_id": id, "text": "A"]]]), state: empty.state, playhead: 0)
        try empty.commit(noOp.edit)
        empty.checkUnchanged(afterFirst, "an unchanged batch")
        let stale = BatchStore(initial)
        stale.state.canvasRatio = .tall9x16
        let edited = stale.state
        checkThrows("a concurrent timeline change rejects the entire prepared batch") { try stale.commit(a.edit) }
        stale.checkUnchanged(edited, "stale batch preserves the user's edit")
    } catch { check(false, "batch commit failed: \(error)") }
}

/// 只计共同提交点调用了几次；不模拟磁吸、联动或 AV 预览（它们由真实 perform 和既有自检负责）。
private final class BatchStore {
    var state: TimelineState
    let undo = UndoManager()
    var commits = 0

    init(_ state: TimelineState) { self.state = state }

    func commit(_ edit: AIBatchEdit) throws {
        _ = try edit.commit(current: state, undo: undo) { next in
            commits += 1
            restore(next)
            return TimelineLinkage.Report()
        }
    }

    func restore(_ snapshot: TimelineState) {
        let old = state
        undo.registerUndo(withTarget: self) { $0.restore(old) }
        state = snapshot
    }

    func checkUnchanged(_ original: TimelineState, _ label: String) {
        checkEqual(state, original, "\(label): no partial changes")
        checkEqual(commits, 0, "\(label): no commit or rebuild request")
        check(!undo.canUndo, "\(label): no undo entry")
    }
}

private func batchForwardingChecks() {
    do {
        let app = try FakeApp()
        let inputs: [(MCPToolName, JSONValue)] = [
            (.editClips, ["project": "p2", "clips": [["clip_id": "12345678", "muted": true], ["clip_id": "87654321", "volume_db": -6]]]),
            (.setTexts, ["project": "p2", "texts": [["text": "hello"], ["text": "goodbye"]]]),
            (.setShapes, ["project": "p2", "shapes": [["kind": "circle"], ["kind": "arc"]]])
        ]
        let requests = inputs.enumerated().map { index, input in
            JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(index + 1)), "method": "tools/call",
                              "params": ["name": .string(input.0.rawValue), "arguments": input.1]]).encodedString()
        }
        let (messages, _) = talkToHelper(requests, socket: app.path)
        // 三次调用可以并发到达；每次调用里的条目顺序必须原样保留。
        let forwarded = app.requests.sorted { $0.tool < $1.tool }
        let expected = inputs.sorted { $0.0.rawValue < $1.0.rawValue }
        checkEqual(forwarded.map(\.tool), expected.map { $0.0.rawValue }, "helper forwards all three batch tools")
        checkEqual(forwarded.map(\.arguments), expected.map { $0.1 }, "helper preserves entry order within each batch and project arguments")
        checkEqual(messages.count, inputs.count, "helper answers every batch call")
    } catch { check(false, "batch helper forwarding failed: \(error)") }
}

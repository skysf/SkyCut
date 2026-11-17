import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - set_text 的 motion_preset：一次调用放一套动效预设（纯值）
//
// 管什么：AI 给的 `motion_preset` / `hit_at` / `small_text` / `small_text_below`（连同 set_text 别的字段）怎么落成一组普通的字和
// 形状 —— 加一套、把一段字（或它所在的那一套）换成另一套、整套挪到新的落点；结果里报这一套。走的是 MotionPresetGroups，
// 和界面上加字的「动效预设」、检查器的「预设」同一条路，两边做出来一样（docs/architecture/motion-presets.md）。
// 只改调用方的副本；提交、一步撤销、排版提示照 set_text 的老路（AIOverlayEdits → AIOverlayTools / AIBatchEditTools）。
// 不管什么：参数说明（SrtFlowMCPKit/MCPTimelineTools.swift）、说明书（MCPGuideTimelineTopics.swift 的 motion_presets 一节）。
//
// 为什么挂在 set_text 上、不另开工具：一套预设的主体就是一段标题字（AI 要给的也就是字、时刻、字体颜色），set_text 的位置、字体、
// 颜色、数字参数原样能用；另开一个长得像的工具违反「不许有两个长得像的工具」（docs/architecture/ai-control-mcp.md 第一节第 5 条）。

/// set_text 里和预设有关的四个参数。
struct AIMotionPresetRequest {
    var kind: MotionPresetKind?
    var hit: Double?
    var small: String?
    var smallBelow: Bool?

    init(_ args: AIToolArguments) throws {
        kind = try args.choice("motion_preset", from: MCPVocabulary.motionPresets).flatMap(MotionPresetKind.init(rawValue:))
        hit = try args.double("hit_at").map { max(0, $0) }
        small = try args.string("small_text").map(AITextChange.unescapingNewlines)
        smallBelow = try args.bool("small_text_below")
    }

    var isEmpty: Bool { kind == nil && hit == nil && small == nil && smallBelow == nil }
}

enum AIMotionPresetEdit {
    /// 带了预设参数（或者改的是一套预设里的字）就在这里做，回标题的 id 和那一组；没带、也不在组里回 nil，照普通 set_text 做。
    static func apply(
        _ args: AIToolArguments, change: AITextChange, at playhead: Double, in state: inout TimelineState
    ) throws -> (id: UUID, group: UUID)? {
        let request = try AIMotionPresetRequest(args)
        guard let raw = try args.string("text_id") else {
            guard !request.isEmpty else { return nil }
            return try add(request, change: change, at: playhead, in: &state)
        }
        let id = try AIShortIDs(state: state).resolve(raw)
        guard state.textOverlays.contains(where: { $0.id == id }) else {
            throw AIToolError("\(raw) is not a text. Call get_timeline for text ids.")
        }
        let current = MotionPresetGroups.members(ofText: id, in: state)
        if let kind = request.kind ?? (request.small != nil || request.smallBelow != nil ? current?.kind : nil) {
            return try reapply(kind, toText: id, request: request, change: change, in: &state)
        }
        if request.small != nil || request.smallBelow != nil {
            throw AIToolError("small_text goes with motion_preset: \(raw) is not in a motion preset. Pass motion_preset to make it one.")
        }
        if let hit = request.hit {
            guard let current else {
                throw AIToolError("hit_at moves a whole motion preset; \(raw) is not in one. Pass motion_preset to make it one, or use start.")
            }
            MotionPresetGroups.move(current.group, toHit: hit, in: &state)
            var rest = change
            rest.start = nil  // hit_at 已经挪了整套
            MotionPresetGroups.update(id, in: &state) { rest.apply(to: &$0) }
            return (id, current.group)
        }
        guard let current else { return nil }
        // 改的是一套预设里的字：照普通 set_text 改它，标题挪了、改了字，同一套的别的几块跟上。
        MotionPresetGroups.update(id, in: &state) { change.apply(to: &$0) }
        return (id, current.group)
    }

    private static func add(
        _ request: AIMotionPresetRequest, change: AITextChange, at playhead: Double, in state: inout TimelineState
    ) throws -> (id: UUID, group: UUID) {
        guard let kind = request.kind else {
            throw AIToolError("hit_at, small_text and small_text_below go with motion_preset; pass motion_preset to add a preset.")
        }
        let words = (change.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw AIToolError("text (the title) is required when adding a motion preset.") }
        if kind == .titleCounter, change.number?.to == nil {
            throw AIToolError("title_counter needs number with at least to, e.g. {\"to\": 20004, \"suffix\": \" KM\"}.")
        }
        var spec = MotionPresetSpec(kind: kind, title: change.text ?? words, hit: request.hit ?? change.start ?? max(0, playhead))
        apply(request, change: change, existingNumber: nil, to: &spec)
        let canvas = TimelineRenderSize.size(for: state)
        let built = MotionPresetGroups.build(spec, canvas: canvas) { styleOnly(change).apply(to: &$0) }
        MotionPresetGroups.place(built, in: &state)
        guard let title = built.anchorText else { throw AIToolError("The motion preset could not be built.") }
        return (title.id, built.group)
    }

    private static func reapply(
        _ kind: MotionPresetKind, toText id: UUID, request: AIMotionPresetRequest, change: AITextChange,
        in state: inout TimelineState
    ) throws -> (id: UUID, group: UUID) {
        // 换成标题 + 数字：没有现成的数字（这一套里的、或者这段字本身就是数字元件）就得给。
        let existing = MotionPresetGroups.members(ofText: id, in: state)?.text(.counter)?.number
            ?? state.textOverlays.first(where: { $0.id == id })?.number
        if kind == .titleCounter, change.number?.to == nil, existing == nil {
            throw AIToolError("title_counter needs number with at least to, e.g. {\"to\": 20004, \"suffix\": \" KM\"}.")
        }
        // 标题的字：给了用给的，没给用这一套的标题 / 这段字自己的字。数字元件没有字：换成框住再放开 / 对焦出字时它自己就是标题
        //（MotionPresetGroups.build），换成标题 + 数字时它当那个数字、标题的字得给。
        let anchor = MotionPresetGroups.members(ofText: id, in: state)?.anchorText ?? state.textOverlays.first(where: { $0.id == id })
        let words = change.text ?? anchor.map { $0.number == nil ? $0.text : "" } ?? ""
        let numberIsTitle = kind != .titleCounter && anchor?.number != nil
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || numberIsTitle else {
            throw AIToolError("text (the title) is required: this text has no words of its own.")
        }
        let built = MotionPresetGroups.reapply(kind, toText: id, in: &state, edit: { spec in
            if let text = change.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spec.title = text }
            if let hit = request.hit ?? change.start { spec.hit = hit }
            apply(request, change: change, existingNumber: spec.number, to: &spec)
        }, adjustTitle: { styleOnly(change).apply(to: &$0) })
        guard let built, let title = built.anchorText else { throw AIToolError("The motion preset could not be built.") }
        return (title.id, built.group)
    }

    /// 时长、位置、字体、颜色、小字、数字落到说法上（只改给了的）。
    private static func apply(
        _ request: AIMotionPresetRequest, change: AITextChange, existingNumber: NumberRoll?, to spec: inout MotionPresetSpec
    ) {
        if let duration = change.duration { spec.duration = duration }
        if let x = change.centerX { spec.center.x = x }
        if let y = change.centerY { spec.center.y = y }
        if let font = change.font { spec.font = font }
        if let color = change.color { spec.color = color }
        if let small = request.small { spec.small = small.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : small }
        if let below = request.smallBelow { spec.smallBelow = below }
        if let number = change.number, !number.remove {
            var holder = TextOverlay(timelineStart: 0)
            holder.number = existingNumber ?? MotionPresetGroups.counterRoll(from: nil)
            number.apply(to: &holder)
            spec.number = holder.number
        }
    }

    /// set_text 剩下的字段（字号、粗细、字距、描边、动画……）落到标题上；字、时间、位置、字体、颜色、数字已经进了说法。
    private static func styleOnly(_ change: AITextChange) -> AITextChange {
        var rest = change
        rest.text = nil
        rest.start = nil
        rest.duration = nil
        rest.centerX = nil
        rest.centerY = nil
        rest.font = nil
        rest.color = nil
        rest.number = nil
        return rest
    }

    /// 结果里报这一套：哪一套、落点、尾、每一块的 id（AI 之后能拿 set_text / set_shape 一块一块地改）。
    static func summary(_ group: UUID, in state: TimelineState) -> JSONValue? {
        guard let members = MotionPresetGroups.members(group, in: state) else { return nil }
        let ids = AIShortIDs(state: state)
        return [
            "preset": .string(members.kind.rawValue),
            "hit_at": AIFormat.seconds(members.hit),
            "end": AIFormat.seconds(members.end),
            "texts": .array(members.textIDs.map { .string(ids.short($0)) }),
            "shapes": .array(members.shapeIDs.map { .string(ids.short($0)) })
        ]
    }
}

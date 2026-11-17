import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 动效预设：放进时间线、换一套、挪落点、跟着标题走（纯值）
//
// 管什么：按 `MotionPresetSpec` 造出一组普通的字和形状（`build`）、放进时间线（`place`）、整组换成另一套而字不变（`reapply`）、
// 整组挪到新的落点（`move`）、拆成普通的字和形状（`detach`）、标题动了之后别的几块跟上（`update` / `follow`）。
// 界面（加字的「动效预设」、检查器「动画」区的「预设」）和 AI（set_text 的 motion_preset）都只调这里，两边做出来一样。
// 不管什么：每套的数（MotionPresetDesign）、怎么量怎么摆（MotionPresetLayout）、提交 / 撤销 / 选中（调用方包在一次
// `perform` 里：一次操作 = 一步撤销）。
//
// 放上去的就是普通的 `TextOverlay` / `ShapeAnnotation`：样式、动画都在它们自己的字段里，照常能一块一块地改；组只是
// `motionPreset` 那个标记（VideoEditTextModels.swift）。规矩写在 docs/architecture/motion-presets.md。

/// 要放一套什么：哪一套、什么字、落在哪一下、摆在哪。
struct MotionPresetSpec: Equatable {
    var kind: MotionPresetKind
    var title: String
    /// 标题上面（或 `smallBelow` 时下面）那一行小字；nil 或空 = 没有。
    var small: String?
    var smallBelow = false
    /// 标题 + 滚动的数字用：数字从哪滚到哪、前后缀。没给等待 / 滚动时长的照样片配（`MotionPresetDesign.counterRoll`）。
    var number: NumberRoll?
    /// 落点（时间线秒）：框开始画 / 标题开始出来的那一刻。
    var hit: Double
    /// 落点到最后一块收走；nil = 这一套的默认。
    var duration: Double?
    /// 整组看得见的范围的中心（画布的比例）。
    var center = CGPoint(x: 0.5, y: 0.5)
    /// 换掉标题和小字的字体（数字不换：老虎机要数字等宽的那副）。
    var font: String?
    /// 字和形状的颜色（框、细线照这一套的透明度）。nil = 白。
    var color: SubtitleColor?
    /// 标题沿用的 id（换预设时标题还是那一段，AI 手里的 text_id 不失效）。
    var titleID: UUID?
}

enum MotionPresetGroups {
    // MARK: 造

    /// 造出一组（还没放进时间线）。`adjustTitle` 在量尺寸之前改标题（AI 给的字号、粗细、动画……），框按改过的字量。
    static func build(
        _ spec: MotionPresetSpec, canvas: CGSize, adjustTitle: (inout TextOverlay) -> Void = { _ in }
    ) -> MotionPresetMembers {
        let design = MotionPresetDesign.of(spec.kind)
        let duration = design.duration(spec.duration)
        var members = MotionPresetMembers(kind: spec.kind, group: UUID())
        func tag(_ role: MotionPresetRole) -> MotionPresetTag { MotionPresetTag(group: members.group, preset: spec.kind, role: role) }

        var title = text(spec.title, face: design.title, font: spec.font, spec: spec, canvas: canvas,
                         beat: design.beat(.title, kind: spec.kind, duration: duration), id: spec.titleID)
        title.motionPreset = tag(.title)
        // 一段数字元件变成框住再放开 / 对焦出字：它自己就是标题（框住的是那个数）。
        if spec.kind != .titleCounter, spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let number = spec.number {
            title.number = number
        }
        let sizeBefore = title.style.fontSize
        let boxBefore = title.boxWidth
        adjustTitle(&title)
        // 给了字号就照给的，不替它收。
        if title.style.fontSize == sizeBefore { MotionPresetLayout.fitWidth(&title, canvas: canvas) }
        // A box_width the caller passed stays; otherwise the wrap width hugs the words (MotionPresetLayout.snugBoxWidth).
        if title.boxWidth == boxBefore { title.boxWidth = MotionPresetLayout.snugBoxWidth(title, canvas: canvas) }
        members.texts.append(title)

        if let small = spec.small, !small.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, spec.kind != .titleCounter {
            let role: MotionPresetRole = spec.smallBelow ? .smallBelow : .smallAbove
            var line = text(small, face: design.small, font: spec.font, spec: spec, canvas: canvas,
                            beat: design.beat(role, kind: spec.kind, duration: duration), id: nil)
            line.motionPreset = tag(role)
            MotionPresetLayout.fitWidth(&line, canvas: canvas)
            line.boxWidth = MotionPresetLayout.snugBoxWidth(line, canvas: canvas)
            members.texts.append(line)
        }
        if spec.kind == .titleCounter {
            var counter = text("", face: design.counter, font: nil, spec: spec, canvas: canvas,
                               beat: design.beat(.counter, kind: spec.kind, duration: duration), id: nil)
            counter.number = spec.number ?? counterRoll(from: nil)
            counter.motionPreset = tag(.counter)
            MotionPresetLayout.fitWidth(&counter, canvas: canvas)
            counter.boxWidth = MotionPresetLayout.snugBoxWidth(counter, canvas: canvas)
            members.texts.append(counter)
            members.shapes.append(shape(.line, role: .rule, design: design, spec: spec, canvas: canvas, duration: duration, tag: tag(.rule)))
        }
        if spec.kind == .frameReveal {
            members.shapes.append(shape(.rectangle, role: .frame, design: design, spec: spec, canvas: canvas, duration: duration, tag: tag(.frame)))
        }
        MotionPresetLayout.arrange(&members, canvas: canvas)
        MotionPresetLayout.center(&members, at: spec.center, canvas: canvas)
        return members
    }

    /// 数字的默认配法：老虎机、千分位、等 0.5 秒滚 1.2 秒（样片）。`roll` 给了的字段照给的。
    static func counterRoll(from roll: NumberRoll?) -> NumberRoll {
        var value = roll ?? NumberRoll.default
        if roll == nil {
            value.from = 0
            value.to = 100
            value.style = .odometer
            value.groupsThousands = true
            value.duration = MotionPresetDesign.counterRoll
            value.delay = MotionPresetDesign.counterDelay
        }
        return value
    }

    private static func text(
        _ words: String, face: MotionPresetDesign.Face, font: String?, spec: MotionPresetSpec, canvas: CGSize,
        beat: MotionPresetBeat, id: UUID?
    ) -> TextOverlay {
        let size = { (design: Double) in MotionPresetLayout.modelSize(design, canvas: canvas) }
        var overlay = TextOverlay(id: id ?? UUID(), text: words, timelineStart: spec.hit + beat.start, duration: beat.length,
                                  centerX: spec.center.x, centerY: spec.center.y, boxWidth: 0.9)
        overlay.style = TextStyle(
            fontName: font ?? face.font, fontSize: size(face.size), bold: face.bold, italic: false,
            fill: .solid(spec.color ?? .white), stroke: nil,
            // 叠在画面上要一点软投影才读得清（样片：模糊 5、偏 2、不透明 45%，720p）。
            shadow: TextShadow(color: SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0.45),
                               offsetX: 0, offsetY: size(3), blur: size(8)),
            background: nil, alignment: .center, lineSpacing: 1, letterSpacing: size(face.tracking)
        )
        overlay.animation = TextAnimation(
            entrance: beat.entrance, exit: beat.exit, entranceDuration: beat.entranceDuration,
            exitDuration: beat.exitDuration, emphasis: .none, intensity: beat.intensity
        )
        return overlay
    }

    private static func shape(
        _ kind: ShapeKind, role: MotionPresetRole, design: MotionPresetDesign, spec: MotionPresetSpec, canvas: CGSize,
        duration: Double, tag: MotionPresetTag
    ) -> ShapeAnnotation {
        let beat = design.shapeBeat(role, duration: duration)
        var color = spec.color ?? .white
        color.opacity *= role == .frame ? 0.92 : 0.8
        var shape = ShapeAnnotation(kind: kind, timelineStart: spec.hit + beat.start, duration: beat.length, color: color,
                                    lineWidth: max(1, MotionPresetLayout.modelSize(design.lineWidth, canvas: canvas)),
                                    centerX: spec.center.x, centerY: spec.center.y, width: 0.3, height: 0.2)
        shape.animation = beat.animation
        shape.motionPreset = tag
        return shape
    }

    // MARK: 放进时间线 / 拿掉

    /// 放进时间线：字各自在最上面新开一行（同新加文字：新的压在旧的上面），形状进形状那一行；夹紧照模型那一处收。
    static func place(_ members: MotionPresetMembers, in state: inout TimelineState) {
        for var text in members.texts {
            text.row = state.textRowCount
            state.textOverlays.append(text)
            state.updateTextOverlay(text.id) { _ in }
        }
        state.shapes.append(contentsOf: members.shapes)
    }

    /// 一组现在在时间线上的几块；没有这一组是 nil。
    static func members(_ group: UUID, in state: TimelineState) -> MotionPresetMembers? {
        let texts = state.textOverlays.filter { $0.motionPreset?.group == group }
        let shapes = state.shapes.filter { $0.motionPreset?.group == group }
        guard let kind = (texts.compactMap(\.motionPreset) + shapes.compactMap(\.motionPreset)).first?.preset else { return nil }
        return MotionPresetMembers(kind: kind, group: group, texts: texts, shapes: shapes)
    }

    static func members(ofText id: UUID, in state: TimelineState) -> MotionPresetMembers? {
        guard let group = state.textOverlays.first(where: { $0.id == id })?.motionPreset?.group else { return nil }
        return members(group, in: state)
    }

    static func remove(_ group: UUID, in state: inout TimelineState) {
        state.textOverlays.removeAll { $0.motionPreset?.group == group }
        state.shapes.removeAll { $0.motionPreset?.group == group }
        state.compactTextRows()
    }

    /// 拆成普通的字和形状：每一块原样留着，只是不再是一组（换预设、挪落点、跟着标题走都不再管它们）。
    static func detach(_ group: UUID, in state: inout TimelineState) {
        for index in state.textOverlays.indices where state.textOverlays[index].motionPreset?.group == group {
            state.textOverlays[index].motionPreset = nil
        }
        for index in state.shapes.indices where state.shapes[index].motionPreset?.group == group {
            state.shapes[index].motionPreset = nil
        }
    }

    // MARK: 换一套（字不变）

    /// 把这段字所在的组（或者这段普通的字）换成 `kind`：字、落点、总长、摆的位置、改过的字体和颜色都留着，旧的几块拿掉、
    /// 按新的一套重新造。标题沿用原来那段字的 id。`edit` 在造之前改说法（AI 给的新字、新落点……）。回新的一组。
    @discardableResult
    static func reapply(
        _ kind: MotionPresetKind, toText id: UUID, in state: inout TimelineState,
        edit: (inout MotionPresetSpec) -> Void = { _ in }, adjustTitle: (inout TextOverlay) -> Void = { _ in }
    ) -> MotionPresetMembers? {
        guard let text = state.textOverlays.first(where: { $0.id == id }) else { return nil }
        let canvas = TimelineRenderSize.size(for: state)
        var spec: MotionPresetSpec
        if let current = members(ofText: id, in: state) {
            spec = MotionPresetGroups.spec(from: current, as: kind, canvas: canvas)
            remove(current.group, in: &state)
        } else {
            spec = MotionPresetGroups.spec(lone: text, as: kind, canvas: canvas)
            state.textOverlays.removeAll { $0.id == id }
            state.compactTextRows()
        }
        edit(&spec)
        let built = build(spec, canvas: canvas, adjustTitle: adjustTitle)
        place(built, in: &state)
        return members(built.group, in: state)
    }

    /// 从时间线上的一组读回「放的是什么」：换成别的一套时用。
    static func spec(from members: MotionPresetMembers, as kind: MotionPresetKind, canvas: CGSize) -> MotionPresetSpec {
        let anchor = members.anchorText
        let old = MotionPresetDesign.of(members.kind)
        var spec = MotionPresetSpec(kind: kind, title: anchor?.text ?? "", hit: members.hit, duration: members.end - members.hit,
                                    titleID: anchor?.id)
        spec.small = members.small?.text
        spec.smallBelow = members.text(.smallBelow) != nil
        spec.number = members.text(.counter)?.number
        let box = MotionPresetLayout.bounds(members, canvas: canvas)
        if !box.isNull, canvas.width > 0, canvas.height > 0 {
            spec.center = CGPoint(x: box.midX / canvas.width, y: box.midY / canvas.height)
        }
        // 用户自己换过的字体、颜色跟着走；还是这一套默认的就交给新的一套。
        if let style = anchor?.style {
            if style.fontName != old.title.font { spec.font = style.fontName }
            if style.fill.primaryColor != .white { spec.color = style.fill.primaryColor }
        }
        return spec
    }

    /// 一段普通的字变成一组：它的字当标题（数字元件的话它就是那个数字）、它的起点当落点、它的时长当总长、它在哪组就摆在哪。
    static func spec(lone text: TextOverlay, as kind: MotionPresetKind, canvas: CGSize) -> MotionPresetSpec {
        var spec = MotionPresetSpec(kind: kind, title: text.number == nil ? text.text : "", hit: text.timelineStart,
                                    duration: text.duration, titleID: text.id)
        spec.number = text.number
        let ink = MotionPresetLayout.ink(text, canvas: canvas)
        if canvas.width > 0, canvas.height > 0 { spec.center = CGPoint(x: ink.midX / canvas.width, y: ink.midY / canvas.height) }
        if text.style.fontName != TextStyle.default.fontName { spec.font = text.style.fontName }
        if text.style.fill.primaryColor != .white { spec.color = text.style.fill.primaryColor }
        return spec
    }

    // MARK: 挪落点

    /// 整组挪到新的落点（每一块平移同样多，各自改过的长短、动画都不动）。挪过去撞上同一行别的字，往上找空行（同拖文字换行）。
    static func move(_ group: UUID, toHit time: Double, in state: inout TimelineState) {
        guard let current = members(group, in: state) else { return }
        let delta = max(0, time) - current.hit
        guard abs(delta) > 1e-9 else { return }
        for text in current.texts {
            state.updateTextOverlay(text.id) { $0.timelineStart += delta }
            guard let moved = state.textOverlays.first(where: { $0.id == text.id }) else { continue }
            let row = state.freeTextRow(from: moved.row, start: moved.timelineStart, end: moved.timelineEnd, ignoring: moved.id)
            if row != moved.row { state.updateTextOverlay(moved.id) { $0.row = row } }
        }
        for shape in current.shapes { state.updateShape(shape.id) { $0.timelineStart += delta } }
        state.compactTextRows()
    }

    // MARK: 跟着标题走

    /// 改一段字，再让它所在的组跟上：界面上每一处改字（检查器、就地编辑、预览上拖 / 缩放）和 AI 的 set_text 都走这里
    ///（VideoEditProject.updateTextOverlay / liveUpdateTextOverlay、AIOverlayEdits）。不在组里的字和以前一样只改它自己。
    static func update(_ id: UUID, in state: inout TimelineState, _ change: (inout TextOverlay) -> Void) {
        let before = state.textOverlays.first { $0.id == id }
        state.updateTextOverlay(id, change)
        guard let before, before.motionPreset != nil else { return }
        keepSnug(id, before: before, in: &state)
        follow(id, before: before, in: &state)
    }

    /// New words or type in a preset text: its wrap width keeps hugging them (the wipe sweeps the box), unless this edit
    /// set the width or someone had set it by hand before (then it is no longer the snug width and stays as it is).
    private static func keepSnug(_ id: UUID, before: TextOverlay, in state: inout TimelineState) {
        guard let after = state.textOverlays.first(where: { $0.id == id }), after.boxWidth == before.boxWidth,
              after.settledText != before.settledText || after.style != before.style else { return }
        let canvas = TimelineRenderSize.size(for: state)
        guard MotionPresetLayout.isSnug(before, canvas: canvas) else { return }
        let snug = MotionPresetLayout.snugBoxWidth(after, canvas: canvas)
        state.updateTextOverlay(id) { $0.boxWidth = snug }
    }

    /// 标题挪了：别的几块平移同样多（各自的微调留着）。标题（或框住的那行小字）改了字、字号、字体：按标题重新排一遍
    ///（框跟着字变大变小、小字和数字贴回去）。别的几块自己挪、自己改，不牵动谁。
    static func follow(_ id: UUID, before: TextOverlay, in state: inout TimelineState) {
        guard let tag = before.motionPreset, let after = state.textOverlays.first(where: { $0.id == id }),
              after.motionPreset == tag, var current = members(tag.group, in: state) else { return }
        let reshaped = after.text != before.text || after.number != before.number || after.style != before.style
            || after.boxWidth != before.boxWidth
        let canvas = TimelineRenderSize.size(for: state)
        switch tag.role {
        case .title where reshaped, .smallAbove where reshaped && tag.preset == .frameReveal:
            MotionPresetLayout.arrange(&current, canvas: canvas)
            write(current, except: id, into: &state)
        case .title:
            let dx = after.centerX - before.centerX
            let dy = after.centerY - before.centerY
            guard abs(dx) > 1e-12 || abs(dy) > 1e-12 else { return }
            for text in current.texts where text.id != id {
                state.updateTextOverlay(text.id) { $0.centerX += dx; $0.centerY += dy }
            }
            for shape in current.shapes { state.updateShape(shape.id) { $0.centerX += dx; $0.centerY += dy } }
        default:
            break
        }
    }

    /// 把排好的位置和框的大小写回时间线（只写位置几何：别的字段可能正被这一次改动改着，不能拿旧值盖）。
    private static func write(_ members: MotionPresetMembers, except id: UUID, into state: inout TimelineState) {
        for text in members.texts where text.id != id {
            state.updateTextOverlay(text.id) { $0.centerX = text.centerX; $0.centerY = text.centerY }
        }
        for shape in members.shapes {
            state.updateShape(shape.id) {
                $0.centerX = shape.centerX
                $0.centerY = shape.centerY
                $0.width = shape.width
                $0.height = shape.height
            }
        }
    }
}

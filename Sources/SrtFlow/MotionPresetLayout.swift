import CoreGraphics
import CoreText
import Foundation

// MARK: - 动效预设：几块怎么量、怎么摆（纯值）
//
// 管什么：量字的墨迹（字形真实画到的地方）、按「标题为锚」把小字、数字、框、细线排好（`arrange`）、整组挪到给定的中心
// （`center`）、字太宽时收字号（`fitWidth`）。放进时间线、换预设、标题动了别的跟着走（MotionPresetGroups）都用这一份。
// 不管什么：每套预设的数（MotionPresetDesign）、放进时间线（MotionPresetGroups）、怎么画（TextRenderer、ShapeOutline）。
//
// **按短边设计**：预设的数是「短边 1080」上的像素。横屏的短边是高、竖屏是宽，于是同一套在 9:16 上占画面宽的比例和在 16:9 上
// 占高的比例一样 —— 不写死像素，也不会到竖屏上大得出画面。存进模型时换成 1080 高的口径（`modelSize`：`TextStyle` 的字号、字距、
// 形状的线宽都按画布高换算）。
//
// **按墨迹摆**，不按版面框：版面框的宽是折行宽度（画面的 80%）、高带着字体上下的留白（`TextLayout.inkBounds` 也是行框），
// 拿它排出来的框和间距比看起来的大一圈。墨迹按每个字形自己的字体量（回退字体的字形号属于回退字体，同 TextDrawing）。

/// 一组里的几块（还没放进时间线，或者从时间线上取出来的）。
struct MotionPresetMembers: Equatable {
    var kind: MotionPresetKind
    var group: UUID
    var texts: [TextOverlay] = []
    var shapes: [ShapeAnnotation] = []

    func textIndex(_ role: MotionPresetRole) -> Int? { texts.firstIndex { $0.motionPreset?.role == role } }
    func shapeIndex(_ role: MotionPresetRole) -> Int? { shapes.firstIndex { $0.motionPreset?.role == role } }
    func text(_ role: MotionPresetRole) -> TextOverlay? { textIndex(role).map { texts[$0] } }
    func shape(_ role: MotionPresetRole) -> ShapeAnnotation? { shapeIndex(role).map { shapes[$0] } }
    /// 组的锚：标题；标题被删了就是剩下的第一段字。
    var anchorText: TextOverlay? { text(.title) ?? texts.first }
    var small: TextOverlay? { text(.smallAbove) ?? text(.smallBelow) }

    /// 落点 = 最早出来的那一块的起点（框住再放开是框、另两套是标题）；整组的尾 = 最晚收走的那一块。
    var hit: Double { (texts.map(\.timelineStart) + shapes.map(\.timelineStart)).min() ?? 0 }
    var end: Double { (texts.map(\.timelineEnd) + shapes.map(\.timelineEnd)).max() ?? 0 }
    var textIDs: [UUID] { texts.map(\.id) }
    var shapeIDs: [UUID] { shapes.map(\.id) }
}

enum MotionPresetLayout {
    /// 这块画布上一个设计单位（短边 1080 上的一个像素）是几个像素。
    static func unit(_ canvas: CGSize) -> Double { min(canvas.width, canvas.height) / 1080 }

    /// 设计单位 → 存进模型的「1080 高」口径（字号、字距、线宽、投影）。
    static func modelSize(_ design: Double, canvas: CGSize) -> Double {
        guard canvas.height > 0 else { return design }
        return design * min(canvas.width, canvas.height) / canvas.height
    }

    // MARK: 量

    /// 字的墨迹在画布上占哪儿（像素，左上原点，未旋转，按定版串）。空文字是中心上的一个点。
    static func ink(_ overlay: TextOverlay, canvas: CGSize) -> CGRect {
        let layout = TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
        let frame = TextRenderer.layoutFrame(overlay, canvas: canvas, layout: layout)
        var ink = CGRect.null
        for line in layout.lines {
            for glyph in line.glyphs {
                var id = glyph.glyph
                var box = CGRect.zero
                CTFontGetBoundingRectsForGlyphs(layout.fonts[glyph.fontIndex], .horizontal, &id, &box, 1)
                guard box.width > 0 || box.height > 0 else { continue }  // 空格
                ink = ink.union(box.offsetBy(dx: glyph.position.x, dy: glyph.position.y))
            }
        }
        guard !ink.isNull else { return CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0) }
        // 排版坐标 y 向上、原点在版面左下；版面在框里竖着居中（同 TextRenderer / TextHitGeometry 的口径）。
        let layoutTop = (frame.height - layout.size.height) / 2
        return CGRect(x: frame.minX + ink.minX, y: frame.minY + layoutTop + (layout.size.height - ink.maxY),
                      width: ink.width, height: ink.height)
    }

    /// 一块形状在画布上看得见的范围（线条的框高是 0：按线宽撑开）。
    static func visible(_ shape: ShapeAnnotation, canvas: CGSize) -> CGRect {
        let frame = shape.frame(in: canvas)
        let stroke = shape.strokeWidth(in: canvas)
        return shape.kind == .line ? frame.insetBy(dx: 0, dy: -stroke / 2) : frame
    }

    /// 整组看得见的范围（字的墨迹 + 形状）。
    static func bounds(_ members: MotionPresetMembers, canvas: CGSize) -> CGRect {
        var result = CGRect.null
        for text in members.texts where !text.isBlank { result = result.union(ink(text, canvas: canvas)) }
        for shape in members.shapes { result = result.union(visible(shape, canvas: canvas)) }
        return result
    }

    // MARK: 挪

    static func move(_ overlay: inout TextOverlay, by delta: CGVector, canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        overlay.centerX += delta.dx / canvas.width
        overlay.centerY += delta.dy / canvas.height
    }

    static func move(_ shape: inout ShapeAnnotation, by delta: CGVector, canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        shape.centerX += delta.dx / canvas.width
        shape.centerY += delta.dy / canvas.height
    }

    /// 整组平移，让看得见的范围的中心落在 `point`（画布的比例）。
    static func center(_ members: inout MotionPresetMembers, at point: CGPoint, canvas: CGSize) {
        let box = bounds(members, canvas: canvas)
        guard !box.isNull else { return }
        let delta = CGVector(dx: point.x * canvas.width - box.midX, dy: point.y * canvas.height - box.midY)
        for index in members.texts.indices { move(&members.texts[index], by: delta, canvas: canvas) }
        for index in members.shapes.indices { move(&members.shapes[index], by: delta, canvas: canvas) }
    }

    /// 一行字太宽就收字号（字距跟着收）：最多占画面宽的 `MotionPresetDesign.maximumWidth`；收到原来的 60% 还放不下，
    /// 就停在那儿让它折行（再小就读不清了）。字自己带的换行照旧。
    static func fitWidth(_ overlay: inout TextOverlay, canvas: CGSize) {
        guard !overlay.isBlank, canvas.width > 0 else { return }
        let explicitLines = overlay.settledText.split(separator: "\n", omittingEmptySubsequences: false).count
        let limit = MotionPresetDesign.maximumWidth * canvas.width
        let original = overlay.style
        for _ in 0..<8 {
            let layout = TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
            let wide = ink(overlay, canvas: canvas).width
            guard layout.lines.count > explicitLines || wide > limit else { return }
            let factor = max(0.82, min(0.95, wide > limit ? limit / wide : 0.9))
            guard overlay.style.fontSize * factor >= original.fontSize * MotionPresetDesign.minimumFit else {
                overlay.style.fontSize = original.fontSize * MotionPresetDesign.minimumFit
                overlay.style.letterSpacing = original.letterSpacing * MotionPresetDesign.minimumFit
                return
            }
            overlay.style.fontSize *= factor
            overlay.style.letterSpacing *= factor
        }
    }

    // MARK: 排

    /// 以标题为锚把别的几块排好：标题不动，小字、框、细线、数字按标题的墨迹摆。放进时间线时排一次，
    /// 标题改了字 / 字号之后再排一次（MotionPresetGroups.follow）。
    static func arrange(_ members: inout MotionPresetMembers, canvas: CGSize) {
        guard let titleIndex = members.textIndex(.title), canvas.width > 0, canvas.height > 0 else { return }
        let design = MotionPresetDesign.of(members.kind)
        let unit = unit(canvas)
        let title = ink(members.texts[titleIndex], canvas: canvas)
        var framed = title

        if let index = members.textIndex(.smallAbove) {
            let placed = place(&members.texts[index], centerX: title.midX, top: nil, bottom: title.minY - design.gapAbove * unit, canvas: canvas)
            framed = framed.union(placed)
        }
        // 框：把标题（和上面那行小字）框在里面，多出一圈；描边全在框内（ShapeOutline），所以再让出半个线宽。
        var below = title.maxY
        if let index = members.shapeIndex(.frame) {
            let stroke = members.shapes[index].strokeWidth(in: canvas)
            let box = framed.insetBy(dx: -(design.framePadding.width * unit + stroke / 2),
                                     dy: -(design.framePadding.height * unit + stroke / 2))
            members.shapes[index].centerX = box.midX / canvas.width
            members.shapes[index].centerY = box.midY / canvas.height
            members.shapes[index].width = box.width / canvas.width
            members.shapes[index].height = box.height / canvas.height
            below = box.maxY
        }
        if let index = members.textIndex(.smallBelow) {
            _ = place(&members.texts[index], centerX: title.midX, top: below + design.gapBelow * unit, bottom: nil, canvas: canvas)
        }
        var counterTop = title.maxY + design.gapBelow * unit
        if let index = members.shapeIndex(.rule) {
            let y = title.maxY + design.ruleGap * unit
            members.shapes[index].centerX = title.midX / canvas.width
            members.shapes[index].centerY = y / canvas.height
            members.shapes[index].width = min(1, design.ruleLength * unit / canvas.width)
            counterTop = y + design.counterGap * unit
        }
        if let index = members.textIndex(.counter) {
            _ = place(&members.texts[index], centerX: title.midX, top: counterTop, bottom: nil, canvas: canvas)
        }
    }

    /// 把一段字挪到：墨迹横向中心在 `centerX`，墨迹的顶在 `top`（或底在 `bottom`）。回挪好之后的墨迹。
    private static func place(
        _ overlay: inout TextOverlay, centerX: Double, top: Double?, bottom: Double?, canvas: CGSize
    ) -> CGRect {
        let now = ink(overlay, canvas: canvas)
        let dy = top.map { $0 - now.minY } ?? bottom.map { $0 - now.maxY } ?? 0
        let delta = CGVector(dx: centerX - now.midX, dy: dy)
        move(&overlay, by: delta, canvas: canvas)
        return now.offsetBy(dx: delta.dx, dy: delta.dy)
    }
}

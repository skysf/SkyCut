import CoreGraphics
import Foundation
import SrtFlowMCPKit

// A canvas change keeps every text's and shape's size on the frame (`OverlayReframe`, called by `CanvasReframe.keepShapes` at the end
// of `perform`) and set_canvas lists them (`AICanvasReframe`: reframed, off_frame). Before the fix, on 16:9 → 9:16 a rectangle went
// from 2.4:1 to 0.8:1, a ring's stroke grew 1.78× while the ring shrank, and every text grew 1.78× against a frame 0.56× as wide.
// Case: docs/bugfixes/2026-11-17-canvas-change-resizes-texts-and-shapes.md.

func runCanvasOverlayChecks() {
    presetSwitchChecks()
    otherCanvasChecks()
    replyChecks()
}

private let wide = CGSize(width: 1920, height: 1080)
private let tall = CGSize(width: 1080, height: 1920)

/// `perform` with the canvas changing: the edit, then the reframe.
private func reframed(_ state: TimelineState, _ edit: (inout TimelineState) -> Void) -> TimelineState {
    var next = state
    edit(&next)
    CanvasReframe.keepShapes(&next, after: state)
    return next
}

private func near(_ a: Double?, _ b: Double?, _ tolerance: Double = 1e-6) -> Bool {
    guard let a, let b else { return false }
    return abs(a - b) <= tolerance
}

private func near(_ a: CGSize?, _ b: CGSize?) -> Bool {
    near(a.map { Double($0.width) }, b.map { Double($0.width) }) && near(a.map { Double($0.height) }, b.map { Double($0.height) })
}

/// A title with stroke, shadow and a plate; a rectangle, a ring, a tilted line and a blur.
private func overlays() -> (state: TimelineState, title: TextOverlay, box: ShapeAnnotation, ring: ShapeAnnotation,
                            line: ShapeAnnotation, blur: ShapeAnnotation) {
    var title = TextOverlay(text: "SOUTH POLE", timelineStart: 0, centerX: 0.5, centerY: 0.3)
    title.style.stroke = TextStroke(color: .black, width: 4)
    title.style.background = TextBackground(color: .translucentBlack, cornerRadius: 12, paddingX: 28, paddingY: 14)
    title.style.letterSpacing = 2
    let box = ShapeAnnotation(kind: .rectangle, timelineStart: 0, lineWidth: 6, centerX: 0.3, centerY: 0.6, width: 0.3, height: 0.22)
    let ring = ShapeAnnotation(kind: .circle, timelineStart: 0, lineWidth: 8, centerX: 0.7, centerY: 0.6, width: 0.2)
    let line = ShapeAnnotation(kind: .line, timelineStart: 0, lineWidth: 6, centerX: 0.5, centerY: 0.8, width: 0.25, rotationDegrees: 30)
    let blur = ShapeAnnotation(kind: .blur, timelineStart: 0, centerX: 0.5, centerY: 0.5, width: 0.15, height: 0.08)
    var state = TimelineState()
    state.canvasRatio = .wide16x9
    state.mainClips = [videoClip(0, 5)]
    state.textOverlays = [title]
    state.shapes = [box, ring, line, blur]
    return (state, title, box, ring, line, blur)
}

private func presetSwitchChecks() {
    let (state, title, box, ring, line, blur) = overlays()
    let narrowed = reframed(state) { $0.canvasRatio = .tall9x16 }
    let text = narrowed.textOverlays.first { $0.id == title.id }
    let pixels = { (style: TextStyle?, canvas: CGSize) in (style?.fontSize ?? 0) * TextOverlay.pixelScale(canvas: canvas) }
    // 16:9 → 9:16: both frames are 1080 on the short side, so a text or shape keeps its pixels.
    check(near(pixels(text?.style, tall), pixels(title.style, wide)), "9:16: the title keeps its letters' size (it was 1.78× before the fix)")
    check(near(text?.style.fontSize, title.style.fontSize * 1080 / 1920), "9:16: …so its font_size reads 54 instead of 96")
    let scale = TextOverlay.pixelScale
    check(near((text?.style.stroke?.width ?? 0) * scale(tall), 4 * scale(wide)), "9:16: the title's stroke keeps its pixels")
    check(near((text?.style.background?.paddingX ?? 0) * scale(tall), 28 * scale(wide)), "9:16: the plate's padding keeps its pixels")
    check(near((text?.style.shadow?.blur ?? 0) * scale(tall), (title.style.shadow?.blur ?? 0) * scale(wide)), "9:16: the shadow keeps its pixels")
    check(near((text?.style.letterSpacing ?? 0) * scale(tall), 2 * scale(wide)), "9:16: the letter spacing keeps its pixels")
    check(near(text?.centerX, 0.5) && near(text?.centerY, 0.3) && near(text?.boxWidth, title.boxWidth),
          "9:16: the title keeps x, y and its wrap width's share of the frame")

    let shape = { (id: UUID) in narrowed.shapes.first { $0.id == id } }
    check(near(shape(box.id)?.frame(in: tall).size, box.frame(in: wide).size), "9:16: the rectangle keeps its pixels (not stretched to 0.8:1)")
    check(near(shape(box.id)?.strokeWidth(in: tall), box.strokeWidth(in: wide)), "9:16: the rectangle's stroke keeps its pixels")
    check(near(shape(ring.id)?.frame(in: tall).size, ring.frame(in: wide).size), "9:16: the ring keeps its diameter")
    check(near(shape(ring.id)?.strokeWidth(in: tall), ring.strokeWidth(in: wide)), "9:16: …and its stroke (no thick blob)")
    check(near(shape(line.id).map { Double($0.frame(in: tall).width) }, Double(line.frame(in: wide).width))
          && near(shape(line.id)?.rotationDegrees, 30),
          "9:16: the line keeps its length and angle")
    check(near(shape(blur.id)?.frame(in: tall).size, blur.frame(in: wide).size), "9:16: the blur covers as many pixels")
    check(near((shape(blur.id)?.coverAmount ?? 0) * 1920 / 1080, blur.coverAmount), "9:16: …just as strongly")
    check(narrowed.shapes.allSatisfy { after in near(after.centerX, state.shapes.first { $0.id == after.id }?.centerX) },
          "9:16: shapes keep x")

    // Back to 16:9: every number returns.
    let back = reframed(narrowed) { $0.canvasRatio = .wide16x9 }
    let returned = back.textOverlays.first { $0.id == title.id }
    check(near(returned?.style.fontSize, title.style.fontSize) && near(returned?.style.stroke?.width, 4)
          && near(returned?.style.background?.paddingY, 14), "back to 16:9: the title's numbers return")
    for original in state.shapes {
        let again = back.shapes.first { $0.id == original.id }
        check(near(again?.width, original.width) && near(again?.height, original.height) && near(again?.lineWidth, original.lineWidth)
              && near(again?.coverAmount, original.coverAmount), "back to 16:9: the \(original.kind.rawValue)'s numbers return")
    }
}

private func otherCanvasChecks() {
    let (state, title, box, _, _, _) = overlays()
    // 16:9 → 4:3: same height, so texts are untouched and shapes only re-express their width.
    let standard = reframed(state) { $0.canvasRatio = .standard4x3 }
    let fourByThree = CGSize(width: 1440, height: 1080)
    check(standard.textOverlays.first { $0.id == title.id } == title, "4:3: the title is untouched (same height, same pixels)")
    check(near(standard.shapes.first { $0.id == box.id }?.frame(in: fourByThree).size, box.frame(in: wide).size),
          "4:3: the rectangle keeps its pixels")

    // Auto from a 4K 16:9 clip to a phone clip (the first clip deleted): same share of the short side as 1080p 16:9 → 9:16.
    var first = videoClip(0, 5)
    first.info?.displaySize = CGSize(width: 3840, height: 2160)
    var phone = videoClip(5, 5)
    phone.info?.displaySize = CGSize(width: 1080, height: 1920)
    var auto = state
    auto.canvasRatio = .auto
    auto.mainClips = [first, phone]
    let deleted = reframed(auto) { $0.remove(first.id) }
    check(near(deleted.textOverlays.first { $0.id == title.id }?.style.fontSize, title.style.fontSize * 1080 / 1920),
          "auto 4K → phone: the title keeps its share of the short side")

    // The edit sized the text itself: left as it set it.
    let resized = reframed(state) { next in
        next.canvasRatio = .tall9x16
        next.updateTextOverlay(title.id) { $0.style.fontSize = 40 }
    }
    check(near(resized.textOverlays.first { $0.id == title.id }?.style.fontSize, 40), "a text the edit sized itself is left as set")

    // Same shape, other size (auto 1920×1080 → fixed 16:9): nothing changes.
    var plain = state
    plain.canvasRatio = .auto
    let same = reframed(plain) { $0.canvasRatio = .wide16x9 }
    check(same.textOverlays == plain.textOverlays && same.shapes == plain.shapes, "same shape: texts and shapes are untouched")
}

private func replyChecks() {
    let set = overlays()
    let (title, box, ring) = (set.title, set.box, set.ring)
    var state = set.state
    // A bar 1152 px wide: inside 16:9, sticking out of 9:16.
    let bar = ShapeAnnotation(kind: .rectangle, timelineStart: 0, centerX: 0.5, centerY: 0.9, width: 0.6, height: 0.05)
    state.shapes.append(bar)
    let narrowed = reframed(state) { $0.canvasRatio = .tall9x16 }
    let ids = AIShortIDs(state: narrowed)
    let fields = AICanvasReframe.fields(before: state, after: narrowed, ids: ids)
    let listed = Set(fields["reframed"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    check([title.id, box.id, ring.id, bar.id].allSatisfy { listed.contains(ids.short($0)) }, "reply: reframed lists the texts and shapes")
    let off = Set(fields["off_frame"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    checkEqual(off, [ids.short(bar.id)], "reply: off_frame lists the bar that now sticks out, nothing else")
    let note = fields["note"]?.stringValue ?? ""
    check(note.contains("font_size") && note.contains("off_frame"), "reply: the note explains reframed texts and off_frame")

    // Eight lines of 150 px fit a 1920-high frame but no 1080-high one: on 9:16 → 16:9 the text block sticks out.
    var tallState = TimelineState()
    tallState.canvasRatio = .tall9x16
    var column = TextOverlay(text: "1\n2\n3\n4\n5\n6\n7\n8", timelineStart: 0, centerX: 0.5, centerY: 0.5)
    column.style.fontSize = 150 * 1080 / 1920
    tallState.textOverlays = [column]
    let block = TextRenderer.layoutFrame(column, canvas: tall)
    check(block.minY >= 0 && block.maxY <= tall.height && block.height > wide.height, "set-up: the column fits 9:16 and is taller than 16:9")
    let widened = reframed(tallState) { $0.canvasRatio = .wide16x9 }
    let tallFields = AICanvasReframe.fields(before: tallState, after: widened, ids: AIShortIDs(state: widened))
    checkEqual(tallFields["off_frame"], .array([.string(AIShortIDs(state: widened).short(column.id))]), "reply: off_frame lists a text that sticks out")

    // fps only: nothing to say about texts or shapes.
    var faster = state
    faster.frameRate = .fps30
    check(AICanvasReframe.fields(before: state, after: faster, ids: AIShortIDs(state: faster)).isEmpty, "fps only: no reframe fields")
}

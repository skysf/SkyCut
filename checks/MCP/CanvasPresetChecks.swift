import CoreGraphics
import Foundation
import SrtFlowMCPKit

// Native preset geometry follows CanvasReframe through both directions and through a change of short-side pixels.
// Fixtures use the production preset builder, typesetter and reply; no media is read or rendered.
enum CanvasPresetChecks {
    private static let wide = CGSize(width: 1920, height: 1080)
    private static let tall = CGSize(width: 1080, height: 1920)

    static func run() {
        for kind in MotionPresetKind.allCases {
            fixedRoundTrip(kind)
            autoRoundTrip(kind)
        }
        wrapPolicies()
        widthOnlyReply()
        minimumFontClamp()
    }

    private static func fixture(_ kind: MotionPresetKind, canvas: CGSize = wide) -> TimelineState {
        var state = TimelineState()
        state.canvasRatio = .wide16x9
        var spec = MotionPresetSpec(kind: kind, title: "SKY LU", small: "FROM", hit: 2.25, duration: nil)
        spec.smallBelow = kind == .focusPull
        if kind == .titleCounter { spec.number = MotionPresetGroups.counterRoll(from: nil) }
        let built = MotionPresetGroups.build(spec, canvas: canvas)
        MotionPresetGroups.place(built, in: &state)
        return state
    }

    private static func changed(_ before: TimelineState, _ edit: (inout TimelineState) -> Void) -> TimelineState {
        var after = before
        edit(&after)
        CanvasReframe.keepShapes(&after, after: before)
        return after
    }

    private static func fixedRoundTrip(_ kind: MotionPresetKind) {
        let before = fixture(kind)
        let narrowed = changed(before) { $0.canvasRatio = .tall9x16 }
        snug(narrowed, canvas: tall, label: "\(kind): 9:16")
        pixels(before, canvas: wide, narrowed, canvas: tall, label: "\(kind): 9:16")
        let back = changed(narrowed) { $0.canvasRatio = .wide16x9 }
        restored(before, back, label: "\(kind): 16:9 round trip")
        if kind == .frameReveal, let title = narrowed.textOverlays.first(where: { $0.motionPreset?.role == .title }) {
            var edited = narrowed
            MotionPresetGroups.update(title.id, in: &edited) { $0.text = "SKY STUDIO" }
            guard let longer = edited.textOverlays.first(where: { $0.id == title.id }) else {
                return check(false, "reframed preset title survives a word edit")
            }
            check(MotionPresetLayout.isSnug(longer, canvas: tall), "typing after a canvas switch still keeps the title snug")
            check(longer.boxWidth > title.boxWidth, "typing longer words grows the reframed snug box")
            checkEqual(TextTypesetter.layout(longer, canvas: tall, text: longer.settledText).lines.count, 1,
                       "typing after the switch still keeps fitting words on one line")
        }
    }

    private static func autoRoundTrip(_ kind: MotionPresetKind) {
        let fourK = CGSize(width: 3840, height: 2160)
        let phone = CGSize(width: 720, height: 1280)
        var before = fixture(kind, canvas: fourK)
        before.canvasRatio = .auto
        var first = videoClip(0, 5)
        first.info?.displaySize = fourK
        var second = videoClip(5, 5)
        second.info?.displaySize = phone
        before.mainClips = [first, second]
        let narrowed = changed(before) { $0.mainClips.removeFirst() }
        checkEqual(TimelineRenderSize.size(for: narrowed), phone, "auto canvas follows the 720×1280 clip")
        snug(narrowed, canvas: phone, label: "\(kind): auto phone")
        pixels(before, canvas: fourK, narrowed, canvas: phone, label: "\(kind): auto phone")
        let back = changed(narrowed) { $0.mainClips = before.mainClips }
        restored(before, back, label: "\(kind): auto 4K round trip")
    }

    private static func snug(_ state: TimelineState, canvas: CGSize, label: String) {
        for text in state.textOverlays {
            check(MotionPresetLayout.isSnug(text, canvas: canvas), "\(label): \(text.motionPreset!.role) remains snug")
            let lines = TextTypesetter.layout(text, canvas: canvas, text: text.settledText).lines
            checkEqual(lines.count, 1, "\(label): fitting fixture words remain on one line")
        }
    }

    private static func pixels(_ before: TimelineState, canvas old: CGSize, _ after: TimelineState, canvas new: CGSize, label: String) {
        let oldShort = min(old.width, old.height)
        let newShort = min(new.width, new.height)
        for text in before.textOverlays {
            guard let kept = after.textOverlays.first(where: { $0.id == text.id }) else {
                check(false, "\(label): text survives")
                continue
            }
            var same = kept
            same.style = text.style
            same.boxWidth = text.boxWidth
            checkEqual(same, text, "\(label): every text keeps its centre and non-size fields during the switch")
            let a = lengths(text.style).map { $0 * old.height / 1080 / oldShort }
            let b = lengths(kept.style).map { $0 * new.height / 1080 / newShort }
            check(zip(a, b).allSatisfy { near($0, $1) }, "\(label): text pixels retain their share of the short side")
        }
        for shape in before.shapes {
            guard let kept = after.shapes.first(where: { $0.id == shape.id }) else {
                check(false, "\(label): shape survives")
                continue
            }
            var same = kept
            same.width = shape.width
            same.height = shape.height
            same.lineWidth = shape.lineWidth
            checkEqual(same, shape, "\(label): each shape keeps its centre and non-size fields during the switch")
            let a = shape.frame(in: old).size
            let b = kept.frame(in: new).size
            check(near(a.width / oldShort, b.width / newShort) && near(a.height / oldShort, b.height / newShort)
                  && near(shape.strokeWidth(in: old) / oldShort, kept.strokeWidth(in: new) / newShort),
                  "\(label): preset frame or rule keeps its size and stroke against the short side")
        }
    }

    private static func restored(_ before: TimelineState, _ after: TimelineState, label: String) {
        checkEqual(after.textOverlays.map(\.id), before.textOverlays.map(\.id), "\(label): same text identities and order")
        checkEqual(after.shapes.map(\.id), before.shapes.map(\.id), "\(label): same shape identities and order")
        for (original, returned) in zip(before.textOverlays, after.textOverlays) {
            check(near(original.boxWidth, returned.boxWidth), "\(label): original snug wrap width returns")
            check(zip(lengths(original.style), lengths(returned.style)).allSatisfy { near($0, $1) },
                  "\(label): all text pixel values return")
            var masked = returned
            masked.style = original.style
            masked.boxWidth = original.boxWidth
            checkEqual(masked, original, "\(label): text tags, centres, timing, animation and number are unchanged")
            styleMetadata(original.style, returned.style, label: label)
        }
        for (original, returned) in zip(before.shapes, after.shapes) {
            check(near(original.width, returned.width) && near(original.height, returned.height)
                  && near(original.lineWidth, returned.lineWidth), "\(label): shape dimensions and line width return")
            var masked = returned
            masked.width = original.width
            masked.height = original.height
            masked.lineWidth = original.lineWidth
            checkEqual(masked, original, "\(label): shape tags, centres, timing and animation are unchanged")
        }
        var masked = after
        masked.textOverlays = before.textOverlays
        masked.shapes = before.shapes
        checkEqual(masked, before, "\(label): the rest of the timeline is untouched")
    }

    private static func lengths(_ style: TextStyle) -> [Double] {
        [style.fontSize, style.letterSpacing, style.stroke?.width ?? 0,
         style.shadow?.offsetX ?? 0, style.shadow?.offsetY ?? 0, style.shadow?.blur ?? 0,
         style.background?.cornerRadius ?? 0, style.background?.paddingX ?? 0, style.background?.paddingY ?? 0]
    }

    private static func styleMetadata(_ a: TextStyle, _ b: TextStyle, label: String) {
        var masked = b
        masked.fontSize = a.fontSize
        masked.letterSpacing = a.letterSpacing
        masked.stroke = a.stroke
        masked.shadow = a.shadow
        masked.background = a.background
        checkEqual(masked, a, "\(label): font, colour, alignment and line spacing stay")
        checkEqual(b.stroke?.color, a.stroke?.color, "\(label): stroke colour stays")
        checkEqual(b.shadow?.color, a.shadow?.color, "\(label): shadow colour stays")
        checkEqual(b.background?.color, a.background?.color, "\(label): plate colour stays")
    }

    private static func wrapPolicies() {
        var before = fixture(.focusPull)
        let title = before.textOverlays.first(where: { $0.motionPreset?.role == .title })!
        before.updateTextOverlay(title.id) { $0.boxWidth = 0.7 }
        let ordinary = TextOverlay(text: "Ordinary words", timelineStart: 0, boxWidth: 0.8)
        before.textOverlays.append(ordinary)
        let narrowed = changed(before) { $0.canvasRatio = .tall9x16 }
        checkEqual(narrowed.textOverlays.first(where: { $0.id == title.id })?.boxWidth, 0.7,
                   "a preset wrap width set by hand keeps its frame fraction")
        checkEqual(narrowed.textOverlays.first(where: { $0.id == ordinary.id })?.boxWidth, 0.8,
                   "an ordinary text keeps its wrap fraction")
        let back = changed(narrowed) { $0.canvasRatio = .wide16x9 }
        checkEqual(back.textOverlays.first(where: { $0.id == title.id })?.boxWidth, 0.7,
                   "a manual preset wrap width returns unchanged")
        checkEqual(back.textOverlays.first(where: { $0.id == ordinary.id })?.boxWidth, 0.8,
                   "an ordinary wrap width returns unchanged")
        let automatic = fixture(.frameReveal)
        let id = automatic.textOverlays.first(where: { $0.motionPreset?.role == .title })!.id
        let explicit = changed(automatic) { state in
            state.canvasRatio = .tall9x16
            state.updateTextOverlay(id) { $0.boxWidth = 0.61 }
        }
        checkEqual(explicit.textOverlays.first(where: { $0.id == id })?.boxWidth, 0.61,
                   "a wrap width set in the same canvas edit is respected")
    }

    private static func widthOnlyReply() {
        let before = fixture(.focusPull)
        let after = changed(before) { $0.canvasRatio = .standard4x3 }
        let title = before.textOverlays.first(where: { $0.motionPreset?.role == .title })!
        let kept = after.textOverlays.first(where: { $0.id == title.id })!
        checkEqual(kept.style, title.style, "4:3 changes no style pixels at the same height")
        check(!near(kept.boxWidth, title.boxWidth), "4:3 re-expresses the snug width alone")
        let ids = AIShortIDs(state: after)
        let fields = AICanvasReframe.fields(before: before, after: after, ids: ids)
        let reported = fields["reframed"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check(reported.contains(ids.short(title.id)), "set_canvas reports a preset text reframed only by its wrap width")
        let note = fields["note"]?.stringValue ?? ""
        check(note.contains("box_width") && note.lowercased().contains("preset"), "set_canvas explains the preset box_width exception")
    }

    private static func minimumFontClamp() {
        var before = fixture(.frameReveal)
        let id = before.textOverlays.first(where: { $0.motionPreset?.role == .title })!.id
        before.updateTextOverlay(id) {
            $0.style.fontSize = TextStyle.fontSizeRange.lowerBound
            $0.boxWidth = MotionPresetLayout.snugBoxWidth($0, canvas: wide)
        }
        let after = changed(before) { $0.canvasRatio = .tall9x16 }
        let kept = after.textOverlays.first(where: { $0.id == id })!
        checkEqual(kept.style.fontSize, TextStyle.fontSizeRange.lowerBound, "canvas conversion clamps the minimum font")
        check(MotionPresetLayout.isSnug(kept, canvas: tall), "snug width is measured from the final clamped font")
        check(near(kept.boxWidth, MotionPresetLayout.snugBoxWidth(kept, canvas: tall)),
              "minimum-font clamp does not leave a box measured with the smaller unclamped font")
    }

    private static func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 1e-7 * max(1, max(abs(a), abs(b)))
    }
}

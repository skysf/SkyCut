import CoreGraphics
import Foundation
import SrtFlowMCPKit

// 动效预设（set_text 的 motion_preset，docs/architecture/motion-presets.md）：一次调用放一套 = 一组普通的字和形状；
// 三套各自的几块、时间、动画；框按字的墨迹框住；竖屏按短边缩；换一套字不变、标题 id 不变；hit_at 整套挪；标题挪了 / 改了字
// 别的跟着走；粘贴出来的自成一组；存盘只在有组时写键、读不懂当没有；词表和 App 的种类对账；报错的几种说法。

func runMotionPresetChecks() {
    checkEqual(MCPVocabulary.motionPresets, MotionPresetKind.allCases.map(\.rawValue), "motion presets match MotionPresetKind")
    motionPresetFrameRevealChecks()
    motionPresetPortraitChecks()
    motionPresetCounterChecks()
    motionPresetSwapAndMoveChecks()
    motionPresetFollowChecks()
    motionPresetErrorChecks()
    motionPresetPasteAndFileChecks()
    runMotionPresetNumberChecks()
}

private func landscape() -> TimelineState {
    var state = TimelineState()
    state.canvasRatio = .wide16x9
    return state
}

/// 一组里的几块（按组号），没有就是 nil。
private func group(_ edit: AIOverlayEdits.Text, _ state: TimelineState) -> MotionPresetMembers? {
    edit.presetGroup.flatMap { MotionPresetGroups.members($0, in: state) }
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

private func motionPresetFrameRevealChecks() {
    var state = landscape()
    guard let edit = try? AIOverlayEdits.text(args([
        "text": "SKY STUDIO", "small_text": "FROM", "motion_preset": "frame_reveal", "hit_at": 25.25
    ]), at: 3, in: &state), let members = group(edit, state) else {
        check(false, "frame_reveal adds a group")
        return
    }
    checkEqual(members.kind, .frameReveal, "the group is a frame reveal")
    checkEqual(members.texts.count, 2, "frame_reveal with small_text: two texts")
    checkEqual(members.shapes.map(\.kind), [.rectangle], "frame_reveal: one rectangle (the frame)")
    checkEqual(members.text(.title)?.id, edit.id, "set_text returns the title's id")
    checkEqual(members.text(.title)?.text, "SKY STUDIO", "the title has the words")
    checkEqual(members.text(.smallAbove)?.text, "FROM", "small_text sits above by default")
    check(near(members.hit, 25.25), "hit_at is when the first piece (the frame) starts, got \(members.hit)")
    check(near(members.end, 28.25), "default length 3 s from hit_at, got \(members.end)")
    if let frame = members.shape(.frame), let title = members.text(.title) {
        checkEqual(frame.animation.entrance, .draw, "the frame draws on")
        checkEqual(frame.animation.exit, .draw, "and draws back off when it lets go")
        check(near(frame.timelineStart, 25.25), "the frame starts on the hit")
        check(frame.timelineEnd < title.timelineEnd - 0.5, "the frame lets go well before the words leave")
        checkEqual(title.animation.entrance, .wipe, "the title wipes in")
        check(near(title.timelineStart, 25.35), "the title starts 0.1 s after the frame")
        let canvas = TimelineRenderSize.size(for: state)
        let box = frame.frame(in: canvas)
        let words = MotionPresetLayout.ink(title, canvas: canvas)
            .union(MotionPresetLayout.ink(members.text(.smallAbove)!, canvas: canvas))
        check(box.insetBy(dx: 2, dy: 2).contains(words), "the frame goes around both lines (frame \(box), words \(words))")
        check(box.width < canvas.width * 0.7, "the frame hugs the words instead of spanning the frame (\(box.width))")
        check(near(box.midX, canvas.width / 2, 1) && near(box.midY, canvas.height / 2, 1), "the group is centred by default (\(box))")
    }
    for text in members.texts { check(text.motionPreset?.group == members.group, "every text carries the group") }
    let rows = Set(state.textOverlays.map(\.row))
    checkEqual(rows.count, 2, "each text of the preset has its own timeline row")
}

private func motionPresetPortraitChecks() {
    var wide = landscape()
    var tall = TimelineState()
    tall.canvasRatio = .tall9x16
    let call: [String: JSONValue] = ["text": "SKY LU", "small_text": "PRESENTS", "small_text_below": true, "motion_preset": "focus_pull"]
    guard let a = try? AIOverlayEdits.text(args(call), at: 1, in: &wide), let b = try? AIOverlayEdits.text(args(call), at: 1, in: &tall),
          let landscapeTitle = group(a, wide)?.text(.title), let portrait = group(b, tall), let portraitTitle = portrait.text(.title) else {
        check(false, "focus_pull adds a group on both frames")
        return
    }
    // 字号按画布高存：竖屏 1920 高，同样占短边的比例，存进去是横屏的 1080 / 1920。
    check(near(portraitTitle.style.fontSize, landscapeTitle.style.fontSize * 1080 / 1920, 0.01),
          "on 9:16 the font size follows the short side (\(portraitTitle.style.fontSize) vs \(landscapeTitle.style.fontSize))")
    let canvas = TimelineRenderSize.size(for: tall)
    for text in portrait.texts {
        let ink = MotionPresetLayout.ink(text, canvas: canvas)
        check(CGRect(origin: .zero, size: canvas).contains(ink), "on 9:16 every line stays in the frame (\(text.text): \(ink))")
    }
    checkEqual(portrait.text(.smallBelow)?.text, "PRESENTS", "small_text_below puts the small line under the title")
    if let below = portrait.text(.smallBelow) {
        check(MotionPresetLayout.ink(below, canvas: canvas).minY > MotionPresetLayout.ink(portraitTitle, canvas: canvas).maxY,
              "the small line is under the title")
        checkEqual(below.animation.entrance, .focus, "focus_pull: the small line focuses in too")
        check(below.timelineStart > portraitTitle.timelineStart + 0.5, "a small line under the title comes in on the release beat")
    }
    checkEqual(portraitTitle.animation.entrance, .focus, "focus_pull: the title focuses in")
    checkEqual(portraitTitle.animation.exit, .focus, "and blurs away")
    checkEqual(portrait.shapes.count, 0, "focus_pull has no shapes")
}

private func motionPresetCounterChecks() {
    var state = landscape()
    checkThrows("title_counter needs number.to") {
        _ = try AIOverlayEdits.text(args(["text": "POLE TO POLE", "motion_preset": "title_counter"]), at: 0, in: &state)
    }
    checkEqual(state.textOverlays.count, 0, "a refused preset leaves nothing behind")
    guard let edit = try? AIOverlayEdits.text(args([
        "text": "POLE TO POLE", "motion_preset": "title_counter", "number": ["to": 20004, "suffix": " KM"], "hit_at": 58.79
    ]), at: 0, in: &state), let members = group(edit, state) else {
        check(false, "title_counter adds a group")
        return
    }
    let counter = members.text(.counter)
    checkEqual(counter?.number?.to, 20004, "the counter rolls to number.to")
    checkEqual(counter?.number?.suffix, " KM", "with the suffix")
    checkEqual(counter?.number?.style, .odometer, "like a slot machine")
    checkEqual(counter?.settledText, "20,004 KM", "with thousands commas")
    check(near(counter?.number?.delay ?? 0, 0.5) && near(counter?.number?.duration ?? 0, 1.2), "it waits 0.5 s and rolls 1.2 s (the sample)")
    checkEqual(members.shape(.rule)?.kind, .line, "a line draws under the title")
    checkEqual(members.text(.title)?.animation.entrance, .pop, "the title pops in")
    check(near(members.end - members.hit, 3.5), "title_counter lasts 3.5 s by default")
    let canvas = TimelineRenderSize.size(for: state)
    if let title = members.text(.title), let rule = members.shape(.rule), let counter {
        let top = MotionPresetLayout.ink(title, canvas: canvas)
        let line = rule.frame(in: canvas)
        let number = MotionPresetLayout.ink(counter, canvas: canvas)
        check(top.maxY < line.midY && line.midY < number.minY, "title, line, number from top to bottom")
        let settled = (counter.number?.settleTime ?? 99) + counter.timelineStart
        check(settled < members.end - 0.4, "the number stops before the end so it can be read")
    }
}

private func motionPresetSwapAndMoveChecks() {
    var state = landscape()
    guard let added = try? AIOverlayEdits.text(args([
        "text": "SKY STUDIO", "small_text": "FROM", "motion_preset": "frame_reveal", "hit_at": 4, "color": "#FFD000"
    ]), at: 0, in: &state), let before = group(added, state) else {
        check(false, "a frame reveal to swap")
        return
    }
    let titleID = AIShortIDs(state: state).short(added.id)
    guard let swapped = try? AIOverlayEdits.text(args(["text_id": .string(titleID), "motion_preset": "focus_pull"]), at: 0, in: &state),
          let after = group(swapped, state) else {
        check(false, "motion_preset with text_id swaps the preset")
        return
    }
    checkEqual(swapped.id, added.id, "the title keeps its id after a swap")
    checkEqual(after.kind, .focusPull, "it is a focus pull now")
    checkEqual(after.text(.title)?.text, "SKY STUDIO", "the words stay")
    checkEqual(after.text(.smallAbove)?.text, "FROM", "the small line stays")
    check(near(after.hit, before.hit), "the hit stays")
    checkEqual(after.text(.title)?.style.fill.primaryColor, try? AIColor.parse("#FFD000"), "a colour the AI chose stays")
    checkEqual(state.shapes.count, 0, "the old frame is gone")
    checkEqual(state.textOverlays.count, 2, "no leftover texts from the old preset")

    guard let moved = try? AIOverlayEdits.text(args(["text_id": .string(titleID), "hit_at": 10]), at: 0, in: &state),
          let shifted = group(moved, state) else {
        check(false, "hit_at with text_id moves the group")
        return
    }
    check(near(shifted.hit, 10), "hit_at moves the whole group (\(shifted.hit))")
    check(near(shifted.end - shifted.hit, after.end - after.hit), "moving keeps every length")
    // 一段普通的字变成一套：它的字、它的起点。
    var plain = landscape()
    guard let lone = try? AIOverlayEdits.text(args(["text": "HELLO", "start": 2]), at: 0, in: &plain) else { return }
    let loneID = AIShortIDs(state: plain).short(lone.id)
    let made = try? AIOverlayEdits.text(args(["text_id": .string(loneID), "motion_preset": "frame_reveal"]), at: 0, in: &plain)
    checkEqual(made.flatMap { group($0, plain) }?.text(.title)?.text, "HELLO", "a plain text becomes the title of a preset")
    checkEqual(made?.id, lone.id, "and keeps its id")
    check(near(made.flatMap { group($0, plain) }?.hit ?? -1, 2), "its start becomes the hit")
}

private func motionPresetFollowChecks() {
    var state = landscape()
    guard let added = try? AIOverlayEdits.text(args([
        "text": "SKY", "small_text": "FROM", "motion_preset": "frame_reveal"
    ]), at: 0, in: &state), let start = group(added, state), let frame = start.shape(.frame),
          let small = start.text(.smallAbove) else {
        check(false, "a frame reveal to follow")
        return
    }
    let id = AIShortIDs(state: state).short(added.id)
    // 标题改了字：框跟着变宽、还是框住它。
    _ = try? AIOverlayEdits.text(args(["text_id": .string(id), "text": "SKY STUDIO PRODUCTIONS"]), at: 0, in: &state)
    guard let longer = MotionPresetGroups.members(start.group, in: state), let wide = longer.shape(.frame),
          let title = longer.text(.title) else { return }
    let canvas = TimelineRenderSize.size(for: state)
    check(wide.width > frame.width + 0.1, "retyping a longer title widens the frame (\(frame.width) → \(wide.width))")
    // The wrap width hugs the words (the wipe sweeps the layout box) and keeps hugging them after retyping, on one line.
    check((start.text(.title)?.boxWidth ?? 1) < 0.3, "a short title's wrap width hugs it (\(start.text(.title)?.boxWidth ?? -1))")
    check(title.boxWidth > (start.text(.title)?.boxWidth ?? 1), "the wrap width grows with the words")
    checkEqual(TextTypesetter.layout(title, canvas: canvas, text: title.settledText).lines.count, 1, "the longer title stays on one line")
    check(wide.frame(in: canvas).insetBy(dx: 2, dy: 2).contains(MotionPresetLayout.ink(title, canvas: canvas)),
          "the frame still goes around the new words")
    // 标题挪了：别的几块平移同样多。
    _ = try? AIOverlayEdits.text(args(["text_id": .string(id), "x": .number(title.centerX - 0.2)]), at: 0, in: &state)
    guard let moved = MotionPresetGroups.members(start.group, in: state), let movedFrame = moved.shape(.frame),
          let movedSmall = moved.text(.smallAbove), let shiftedSmall = longer.text(.smallAbove) else { return }
    check(near(movedFrame.centerX, wide.centerX - 0.2), "moving the title moves the frame with it")
    check(near(movedSmall.centerX, shiftedSmall.centerX - 0.2), "and the small line")
    check(near(movedSmall.centerY, small.centerY, 0.05), "the small line stays above the title")
    // A wrap width set by hand stays when the words change.
    _ = try? AIOverlayEdits.text(args(["text_id": .string(id), "box_width": 0.8]), at: 0, in: &state)
    _ = try? AIOverlayEdits.text(args(["text_id": .string(id), "text": "SKY"]), at: 0, in: &state)
    checkEqual(MotionPresetGroups.members(start.group, in: state)?.text(.title)?.boxWidth, 0.8, "a box_width set by hand is kept")
    // 别的几块自己挪：不牵动标题。
    let smallID = AIShortIDs(state: state).short(movedSmall.id)
    _ = try? AIOverlayEdits.text(args(["text_id": .string(smallID), "y": 0.1]), at: 0, in: &state)
    checkEqual(MotionPresetGroups.members(start.group, in: state)?.text(.title)?.centerY, moved.text(.title)?.centerY,
               "moving the small line on its own leaves the title")
}

private func motionPresetErrorChecks() {
    var state = landscape()
    guard let plain = try? AIOverlayEdits.text(args(["text": "Plain"]), at: 0, in: &state) else { return }
    let id = AIShortIDs(state: state).short(plain.id)
    checkThrows("hit_at on a text that is not in a preset") {
        _ = try AIOverlayEdits.text(args(["text_id": .string(id), "hit_at": 3]), at: 0, in: &state)
    }
    checkThrows("small_text without motion_preset on a plain text") {
        _ = try AIOverlayEdits.text(args(["text_id": .string(id), "small_text": "FROM"]), at: 0, in: &state)
    }
    checkThrows("hit_at without motion_preset when adding") {
        _ = try AIOverlayEdits.text(args(["text": "New", "hit_at": 3]), at: 0, in: &state)
    }
    checkThrows("a preset needs the title words") {
        _ = try AIOverlayEdits.text(args(["motion_preset": "focus_pull"]), at: 0, in: &state)
    }
    checkThrows("an unknown preset name") {
        _ = try AIOverlayEdits.text(args(["text": "X", "motion_preset": "explode"]), at: 0, in: &state)
    }
    checkEqual(state.textOverlays.count, 1, "refused calls change nothing")
    // 批量：一项一套，一次放好。
    guard let batch = try? AITextBatch(args(["texts": [
        ["text": "ONE", "motion_preset": "focus_pull"], ["text": "TWO", "motion_preset": "frame_reveal", "hit_at": 5]
    ]]), state: landscape(), playhead: 0) else {
        check(false, "set_texts takes motion presets")
        return
    }
    checkEqual(Set(batch.entries.compactMap(\.presetGroup)).count, 2, "two entries, two groups")
    checkEqual(batch.edit.next.shapes.count, 1, "the frame reveal brought its frame")
}

private func motionPresetPasteAndFileChecks() {
    var state = landscape()
    guard let added = try? AIOverlayEdits.text(args(["text": "SKY", "small_text": "FROM", "motion_preset": "frame_reveal"]), at: 0, in: &state),
          let original = group(added, state) else { return }
    let all = TimelineClipboardPayload(copying: state, clips: [], shapes: Set(original.shapeIDs), texts: Set(original.textIDs), cues: [], filters: [])
    if let all {
        let pasted = TimelinePaste.apply(all, to: &state, at: 20, pointing: nil)
        let groups = Set(state.textOverlays.filter { pasted.texts.contains($0.id) }.compactMap(\.motionPreset?.group))
        checkEqual(groups.count, 1, "a pasted preset is one group")
        check(!groups.contains(original.group), "with a new group number, not tied to the original")
        checkEqual(MotionPresetGroups.members(original.group, in: state)?.texts.count, 2, "the original group is unchanged")
    }
    if let one = TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [added.id], cues: [], filters: []) {
        let pasted = TimelinePaste.apply(one, to: &state, at: 40, pointing: nil)
        check(state.textOverlays.filter { pasted.texts.contains($0.id) }.allSatisfy { $0.motionPreset == nil },
              "a single piece pasted on its own is a plain text")
    }
    // 存盘：有组才写键、往返不丢；读不懂的预设当普通的字；没有组的不写键。
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(state), let back = try? JSONDecoder().decode(TimelineState.self, from: data) {
        checkEqual(back.textOverlays.map(\.motionPreset), state.textOverlays.map(\.motionPreset), "the group tags survive a save")
        checkEqual(back.shapes.map(\.motionPreset), state.shapes.map(\.motionPreset), "the shape tags too")
    } else {
        check(false, "a timeline with presets saves and loads")
    }
    if let plain = try? encoder.encode(TextOverlay(text: "x", timelineStart: 0)), let text = String(data: plain, encoding: .utf8) {
        check(!text.contains("motionPreset"), "a plain text writes no motionPreset key")
    }
    let future = #"{"text":"x","timelineStart":0,"motionPreset":{"group":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","preset":"explode","role":"title"}}"#
    let decoded = try? JSONDecoder().decode(TextOverlay.self, from: Data(future.utf8))
    check(decoded != nil && decoded?.motionPreset == nil, "a preset this version does not know reads as a plain text")
}

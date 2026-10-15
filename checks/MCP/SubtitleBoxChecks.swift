import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 每句字幕在画布上占哪一块（SubtitleLineBoxes / AISubtitleBoxes）、撞没撞上画面里的字（AISubtitleOverlaps，2026-10-15 用户转来的
// 反馈：三行字幕碰到左下角的台标，AI 只能一帧一帧 look）：一行的位置和高按样式（底部 / 左 / 右上、边距、描边）、字多就宽、
// 太长就折（折在哪儿只问 SubtitleLineWrap，和预览、成片同一处）、没有空格的中文在字之间折（烧录把折行点写成 \N）、框不比画面宽、
// max_width 小了折得早、拖框的布局按它的边距居中、竖屏更早折；叠在一起的两条轨原文在上译文在下、
// 分开摆各归各位；只算一段时间里的；宽行撞上左下角的台标、短的不撞、不在这段时间里的不查、擦过去不算；结果里报进 text_scan。
// 位置和高的容差 2 px（0.002）：几何是确定的（块高 = 行数 × 字号、底边 = 边距 + 描边），松到 0.01 连 3 px 的描边漏掉都看不出来。
// 编法见 scripts/check-mcp.sh。

func runSubtitleBoxChecks() {
    lineBoxChecks()
    stackedBoxChecks()
    overlapChecks()
}

private let wide = CGSize(width: 1920, height: 1080)

private func lineBoxChecks() {
    // 默认样式：Helvetica 56 粗体、描边 3、底部正中、上下边距 60、左右边距 80。
    var style = BurnInStyle(name: "check")
    let short = SubtitleLineBoxes.box(for: "Hi there", style: style, layout: nil, canvas: wide)
    checkEqual(short?.lineCount, 1, "a short line is one row")
    check(abs((short?.rect.midX ?? 0) - 0.5) < 0.01, "bottom-centre: centred horizontally (got \(short?.rect.midX ?? -1))")
    check(abs((short?.rect.maxY ?? 0) - (1020.0 + 3) / 1080) < 0.002, "…its bottom on the vertical margin plus the outline (got \(short?.rect.maxY ?? -1))")
    check(abs((short?.rect.height ?? 0) - 62.0 / 1080) < 0.002, "one row is the font size tall plus the outline (got \(short?.rect.height ?? -1))")
    let longer = SubtitleLineBoxes.box(for: "Hi there, how are you", style: style, layout: nil, canvas: wide)
    check((longer?.rect.width ?? 0) > (short?.rect.width ?? 0) * 1.8, "more words, wider box")
    let wrapped = SubtitleLineBoxes.box(for: String(repeating: "wide words keep coming ", count: 6), style: style, layout: nil, canvas: wide)
    check((wrapped?.lineCount ?? 0) >= 2, "a long line wraps (\(wrapped?.lineCount ?? 0) rows)")
    check((wrapped?.rect.width ?? 1) <= (1920.0 - 160 + 6) / 1920 + 1e-6, "…never wider than the frame minus the margins")
    check((wrapped?.rect.height ?? 0) > (short?.rect.height ?? 0) * 1.8, "…and at least two rows tall")
    // 没有空格的中文在字之间折（SubtitleLineWrap；libass 只在空格处折，烧录把算好的折行点写成 \N，2026-10-15）：框和英文一样
    // 折成几行、不比画面减边距宽 —— 预览、成片也是这几行（check-subtitle-burn-size 的 WrapChecks 钉着两边）。
    let chinese = SubtitleLineBoxes.box(for: String(repeating: "南极的冰盖一望无际", count: 6), style: style, layout: nil, canvas: wide)
    check((chinese?.lineCount ?? 0) >= 2, "Chinese without spaces wraps between characters (\(chinese?.lineCount ?? 0) rows)")
    check((chinese?.rect.width ?? 1) <= (1920.0 - 160 + 6) / 1920 + 1e-6, "…and its box stays inside the margins (got \(chinese?.rect.width ?? -1))")
    let chineseSpaced = SubtitleLineBoxes.box(for: String(repeating: "南极的冰盖一望无际 ", count: 6), style: style, layout: nil, canvas: wide)
    check((chineseSpaced?.lineCount ?? 0) >= 2, "Chinese with spaces wraps at the spaces")
    // 折成几行就是 SubtitleLineWrap 说的几行（同一个函数）。
    let wrappedText = String(repeating: "wide words keep coming ", count: 6)
    let wrapLines = SubtitleLineWrap.lines(of: wrappedText, runs: SubtitleFontScale.runs(wrappedText, style: style), style: style,
                                           fontSize: style.fontSize, letterSpacing: 0, maxWidth: 1760)
    checkEqual(wrapped?.lineCount, wrapLines.count, "the box has as many rows as SubtitleLineWrap folds the text into")

    style.position = .bottomLeft
    let left = SubtitleLineBoxes.box(for: "Hi there", style: style, layout: nil, canvas: wide)
    check(abs((left?.rect.minX ?? 0) - (80.0 - 3) / 1920) < 0.002, "bottom-left starts at the horizontal margin (got \(left?.rect.minX ?? -1))")
    style.position = .topRight
    let right = SubtitleLineBoxes.box(for: "Hi there", style: style, layout: nil, canvas: wide)
    check(abs((right?.rect.maxX ?? 0) - (1920.0 - 80 + 3) / 1920) < 0.002, "top-right ends at the margin (got \(right?.rect.maxX ?? -1))")
    check(abs((right?.rect.minY ?? 0) - (60.0 - 3) / 1080) < 0.002, "…and starts at the top margin (got \(right?.rect.minY ?? -1))")
    style.position = .bottomCenter
    style.marginHorizontal = 600
    let narrow = SubtitleLineBoxes.box(for: "Hi there, how are you doing today my friend", style: style, layout: nil, canvas: wide)
    check((narrow?.lineCount ?? 0) >= 2, "a smaller max_width wraps sooner")
    style.marginHorizontal = 80
    style.borderStyle = .box
    style.outlineWidth = 10
    let boxed = SubtitleLineBoxes.box(for: "Hi there", style: style, layout: nil, canvas: wide)
    check(abs((boxed?.rect.height ?? 0) - 76.0 / 1080) < 0.002, "a box adds its padding on both sides (got \(boxed?.rect.height ?? -1))")
    style.borderStyle = .outline
    style.outlineWidth = 3
    let layout = SubtitleLayout(marginLeft: 400, marginRight: 100, marginBottom: 200)
    let dragged = SubtitleLineBoxes.box(for: "Hi there", style: style, layout: layout, canvas: wide)
    check(abs((dragged?.rect.midX ?? 0) - (400.0 + 1820) / 2 / 1920) < 0.01, "a dragged layout centres the line between its margins (got \(dragged?.rect.midX ?? -1))")
    check(abs((dragged?.rect.maxY ?? 0) - (880.0 + 3) / 1080) < 0.002, "…and sits on its marginBottom (got \(dragged?.rect.maxY ?? -1))")
    check(SubtitleLineBoxes.box(for: "  \n ", style: style, layout: nil, canvas: wide) == nil, "no text, no box")
    let portrait = SubtitleLineBoxes.box(for: "Hi there, how are you doing today", style: style, layout: nil, canvas: CGSize(width: 1080, height: 1920))
    check((portrait?.lineCount ?? 0) >= 2, "on 9:16 the same words wrap")
    let twoRows = SubtitleLineBoxes.box(for: "one\ntwo", style: style, layout: nil, canvas: wide)
    checkEqual(twoRows?.lineCount, 2, "a line break in the text counts as a row")
}

private func stackedState() -> (state: TimelineState, original: SubtitleCue, translated: SubtitleCue) {
    var state = TimelineState()
    var document = SubtitleDocumentModel(format: .srt)
    let original = SubtitleCue(id: UUID(), start: 0, end: 2, text: "I found a love")
    document.cues = [original]
    state.subtitle = document
    var translation = SubtitleDocumentModel(format: .srt)
    let translated = SubtitleCue(id: UUID(), start: 0, end: 2, text: "我找到了爱")
    translation.cues = [translated]
    var companion = state.subtitleCompanion ?? SubtitleCompanion()
    companion.translation = translation
    state.subtitleCompanion = companion
    return (state, original, translated)
}

private func stackedBoxChecks() {
    var (state, original, translated) = stackedState()
    let style = BurnInStyle(name: "check")
    let blocks = state.subtitleScreenBlocks()
    checkEqual(blocks.count, 1, "two visible tracks without their own layout form one stacked block")
    let boxes = AISubtitleBoxes.boxes(in: blocks, style: style, canvas: wide)
    guard let top = boxes[original.id], let bottom = boxes[translated.id] else {
        check(false, "both lines of a stacked block have boxes")
        return
    }
    check(abs(top.rect.maxY - bottom.rect.minY) < 0.012, "the original sits right above the translation (\(top.rect.maxY) vs \(bottom.rect.minY))")
    check(abs(bottom.rect.maxY - (1020.0 + 3) / 1080) < 0.002, "the translation sits on the bottom margin (got \(bottom.rect.maxY))")
    check(top.rect.width > bottom.rect.width, "each takes the width of its own words")
    checkEqual(AISubtitleBoxes.boxes(in: blocks, style: style, canvas: wide, within: 5...6).count, 0, "a range the lines do not touch yields nothing")
    state.translationLayout = SubtitleLayout(marginLeft: 80, marginRight: 80, marginBottom: 500)
    let separate = AISubtitleBoxes.boxes(in: state.subtitleScreenBlocks(), style: style, canvas: wide)
    check(abs((separate[translated.id]?.rect.maxY ?? 0) - (580.0 + 3) / 1080) < 0.002, "a translation with its own layout sits where that layout puts it")
    check(abs((separate[original.id]?.rect.maxY ?? 0) - (1020.0 + 3) / 1080) < 0.002, "…and the original is back on the bottom margin")
    state.translationLayout = nil
    var companion = state.subtitleCompanion ?? SubtitleCompanion()
    companion.hiddenCueIDs.insert(translated.id)
    state.subtitleCompanion = companion
    let hidden = AISubtitleBoxes.boxes(in: state.subtitleScreenBlocks(), style: style, canvas: wide)
    check(hidden[translated.id] == nil, "a hidden line has no box")
    check(abs((hidden[original.id]?.rect.maxY ?? 0) - (1020.0 + 3) / 1080) < 0.002, "…and the original alone drops to the bottom margin")
}

private func overlapChecks() {
    let style = BurnInStyle(name: "check")
    var state = TimelineState()
    var document = SubtitleDocumentModel(format: .srt)
    let long = SubtitleCue(id: UUID(), start: 0, end: 2, text: "A subtitle that runs all the way across the picture bottom")
    let short = SubtitleCue(id: UUID(), start: 2, end: 4, text: "Short")
    let later = SubtitleCue(id: UUID(), start: 30, end: 32, text: "A subtitle that runs all the way across the picture bottom")
    document.cues = [long, short, later]
    state.subtitle = document
    let blocks = state.subtitleScreenBlocks()
    let boxes = AISubtitleBoxes.boxes(in: blocks, style: style, canvas: wide, within: 0...10)
    checkEqual(Set(boxes.keys), Set([long.id, short.id]), "only lines inside the clip's time get boxes")
    let corner = CGRect(x: 0.02, y: 0.9, width: 0.2, height: 0.08)
    let marks = [AISubtitleOverlaps.Mark(name: "Sky Studio", rects: [corner])]
    let cues = [(cue: long, track: SubtitleTrack.original), (cue: short, track: .original), (cue: later, track: .original)]
    let found = AISubtitleOverlaps.find(marks: marks, boxes: boxes, cues: cues)
    checkEqual(found.map(\.cueID), [long.id], "the wide line reaches the corner mark; the short one does not; the later one is not checked")
    checkEqual(found.first?.marks, ["Sky Studio"], "…and it says which mark")
    check(!AISubtitleOverlaps.meets(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.499, y: 0.2, width: 0.3, height: 0.3)),
          "grazing by less than half a percent is not a hit")

    var payload: [String: JSONValue] = ["fixed_text": .array([])]
    let clip = videoClip(0, 10)
    let report = AITextRegions.Report(band: nil, fixed: [AITextRegions.Fixed(text: "Sky Studio", box: corner, coverage: 0.6)], heavy: nil)
    AISubtitleOverlaps.annotate(&payload, report: report, clip: clip, state: state, style: style, canvas: wide, ids: AIShortIDs(state: state))
    checkEqual(payload["subtitles_checked"]?.doubleValue, 2, "two lines are shown during the clip")
    let overlaps = payload["subtitle_overlaps"]?.arrayValue ?? []
    checkEqual(overlaps.count, 1, "one of them overlaps")
    checkEqual(overlaps.first?["text"]?.stringValue, long.text, "…named by its text")
    checkEqual(overlaps.first?["overlaps"]?.arrayValue?.first?.stringValue, "Sky Studio", "…and by the mark")
    check(payload["subtitle_overlaps_hint"]?.stringValue?.contains("max_width") == true, "with a hint on what to do")
    var nothing: [String: JSONValue] = [:]
    AISubtitleOverlaps.annotate(&nothing, report: AITextRegions.Report(), clip: clip, state: state, style: style, canvas: wide, ids: AIShortIDs(state: state))
    check(nothing.isEmpty, "nothing found in the picture: nothing to report")
    var band: [String: JSONValue] = [:]
    let bandReport = AITextRegions.Report(band: AITextRegions.Band(box: CGRect(x: 0.2, y: 0.88, width: 0.6, height: 0.08), coverage: 0.5, from: 0, to: 10))
    AISubtitleOverlaps.annotate(&band, report: bandReport, clip: clip, state: state, style: style, canvas: wide, ids: AIShortIDs(state: state))
    checkEqual(band["subtitle_overlaps"]?.arrayValue?.count, 2, "both lines shown during the clip sit on a burned-in subtitle band")
    checkEqual(band["subtitle_overlaps"]?.arrayValue?.first?["overlaps"]?.arrayValue?.first?.stringValue, "burned-in subtitles", "…which is named")
}

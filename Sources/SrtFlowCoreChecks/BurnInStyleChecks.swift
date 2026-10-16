import Foundation
import SrtFlowCore

// 烧录样式 → ASS（从 main.swift 搬出来，2026-10-16：main.swift 是登记过的老超标文件，只许降不许涨）：虚拟画布 1080 高、宽按宽高比；
// 样式行、\N、源文件自带的标签清掉、所有条目指到我们的样式；内置预设；底框走 BorderStyle 3；行距（lineSpacing：老文件缺键读 1、
// 超出 1–2 夹回去、垫片 {\fs…}\h{\fs字号} 的样子）。

func runBurnInStyleChecks() {
    var style = BurnInStyle.default
    style.fontName = "Hiragino Sans GB"
    style.fontSize = 56
    style.position = .bottomCenter
    style.marginVertical = 60

    let cues = [
        SubtitleCue(index: 1, start: 1, end: 3, text: "第一行\n第二行", styleName: "SomeOtherStyle"),
        // 源文件自带的覆盖标签必须被清掉，否则会盖过界面上调的样式。
        SubtitleCue(index: 2, start: 4, end: 6, text: "{\\pos(100,200)\\c&H00FF00&}带标签的文本")
    ]
    let ass = style.assDocument(cues: cues, aspectRatio: 16.0 / 9.0, title: "Demo")

    check(ass.contains("PlayResY: 1080"), "burn-in ASS uses 1080p reference canvas")
    check(ass.contains("PlayResX: 1920"), "burn-in ASS canvas width from aspect ratio")
    check(ass.contains("ScaledBorderAndShadow: yes"), "burn-in ASS scales border and shadow")
    check(ass.contains("Style: SrtFlow,Hiragino Sans GB,56,"), "burn-in ASS style line")
    check(ass.contains(",Default,") == false, "burn-in ASS has no leftover Default style reference")
    check(ass.contains("第一行\\N第二行"), "burn-in ASS keeps line breaks as \\N")
    check(!ass.contains("\\pos(100,200)"), "burn-in ASS strips source override tags")
    check(ass.contains("带标签的文本"), "burn-in ASS keeps text after stripping tags")
    // 所有条目都指到我们的样式，源里的 styleName 一律忽略。
    checkEqual(ass.components(separatedBy: "Dialogue: ").count - 1, 2, "burn-in ASS dialogue count")
    check(!ass.contains("SomeOtherStyle"), "burn-in ASS overrides per-cue style name")

    // 竖屏：画布宽度跟着宽高比变。
    let vertical = style.assDocument(cues: cues, aspectRatio: 1080.0 / 1920.0)
    check(vertical.contains("PlayResX: 608"), "burn-in ASS vertical canvas width")
    // 宽高比非法时回退到 16:9，而不是算出 0 或 NaN。
    check(style.assDocument(cues: [], aspectRatio: 0).contains("PlayResX: 1920"), "burn-in ASS falls back to 16:9")

    checkEqual(BurnInStyle.builtInPresets.count, 5, "built-in preset count")
    check(BurnInStyle.builtInPresets.allSatisfy(\.isBuiltIn), "presets marked built-in")
    checkEqual(Set(BurnInStyle.builtInPresets.map(\.id)).count, 5, "preset ids are unique")

    // 行距（2026-10-16）：老文件 / 烧录页记住的老预设没有 lineSpacing 键 → 1（以前的样子）；存过的原样回来、超出 1–2 的夹回去；
    // 不为它 +1 工程文件版本（老版本忽略不认识的键）。
    if let data = try? JSONEncoder().encode(BurnInStyle.default),
       var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        json["lineSpacing"] = nil
        let stripped = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(BurnInStyle.self, from: $0) }
        checkEqual(stripped?.lineSpacing, 1, "burn-in style without a lineSpacing key reads as 1")
        checkEqual(stripped, BurnInStyle.default, "…and is otherwise the same style")
        json["lineSpacing"] = 1.4
        let kept = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(BurnInStyle.self, from: $0) }
        checkEqual(kept?.lineSpacing, 1.4, "burn-in style keeps a stored lineSpacing")
        json["lineSpacing"] = 3.5
        let clamped = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(BurnInStyle.self, from: $0) }
        checkEqual(clamped?.lineSpacing, 2, "burn-in style clamps lineSpacing to 1–2")
    } else {
        check(false, "could not encode the default burn-in style")
    }
    checkEqual(BurnInStyle(name: "x", lineSpacing: 0.4).lineSpacing, 1, "burn-in style init clamps lineSpacing up to 1 (it can only widen)")
    checkEqual(BurnInStyle.assNumber(16.8), "16.8", "ASS numbers: trailing zeros trimmed")
    checkEqual(BurnInStyle.assNumber(56), "56", "ASS numbers: whole numbers have no point")
    checkEqual(BurnInStyle.lineSpacer(fontSize: 56, lineSpacing: 1), nil, "line spacing 1: no spacer")
    checkEqual(BurnInStyle.lineSpacer(fontSize: 56, lineSpacing: 1.3), "{\\fs16.8}\\h{\\fs56}", "line spacing 1.3 at 56: a 16.8-high spacer line, then back to 56")

    // 半透明底框那一档应该走 BorderStyle 3。
    guard let box = BurnInStyle.builtInPresets.first(where: { $0.borderStyle == .box }) else {
        check(false, "a box-style preset exists"); exit(1)
    }
    checkEqual(box.assStyle.borderStyle, 3, "box preset maps to ASS BorderStyle 3")
    // libass 在 BorderStyle 3 下是用 OutlineColour 画底框的，BackColour 只管投影。
    // 底框颜色若是透明、内边距若是 0，底框就整个不见了 —— 这里钉住这个语义。
    check(box.outlineColor.opacity > 0, "box preset's box colour is actually visible")
    check(box.outlineWidth > 0, "box preset has non-zero box padding")
    check(box.borderStyle.usesOutlineColorAsBox, "box mode repurposes the outline colour")
    check(!SubtitleBorderStyle.outline.usesOutlineColorAsBox, "outline mode keeps the outline colour")

    checkEqual(SubtitlePosition.bottomCenter.assAlignment, 2, "bottom-center alignment")
    checkEqual(SubtitlePosition.topRight.assAlignment, 9, "top-right alignment")
    checkEqual(SubtitlePosition.middleCenter.row, 1, "middle row index")
    checkEqual(SubtitlePosition.bottomRight.column, 2, "right column index")
}

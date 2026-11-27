import AppKit
import SwiftUI

// scripts/check-app-theme.sh: on / off, current and selected tell apart at a glance, measured on the palette's own values
// (docs/architecture/app-themes.md "On / off at a glance"). A state shows when its mark (the icon or text colour) differs
// from the other state's by CIEDE2000 >= 20, or its area (a chip, a row fill, an outline, against what is behind it) by
// >= 10; a current line's text keeps WCAG contrast >= 3 on its own background. The old Forest toggles (#123F32 on,
// #19221D off, no chip) and the old Forest current line (the accent against the primary text, no chip) must fail.
// Classic is measured with its own colours in system light and dark, with the default (blue) macOS accent: another
// accent is the user's own setting, and Classic's accent sites are pinned to `Color.accentColor` itself.

struct StateRGB {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xff) / 255, g: Double((hex >> 8) & 0xff) / 255, b: Double(hex & 0xff) / 255)
    }

    /// This colour, with its own alpha, over an opaque background.
    func over(_ background: StateRGB) -> StateRGB {
        StateRGB(r: a * r + (1 - a) * background.r, g: a * g + (1 - a) * background.g, b: a * b + (1 - a) * background.b)
    }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// CIE L*a*b* (D65).
    var lab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}

enum StateRule {
    static let markMinimum = 20.0
    static let areaMinimum = 10.0
    static let textMinimum = 3.0

    /// One state as it is seen: the mark's colour and the area right behind or around it.
    struct Look { var mark: StateRGB; var area: StateRGB }

    static func tellsApart(_ on: Look, _ off: Look) -> Bool {
        deltaE(on.mark, off.mark) >= markMinimum || deltaE(on.area, off.area) >= areaMinimum
    }

    static func contrast(_ a: StateRGB, _ b: StateRGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// CIEDE2000.
    static func deltaE(_ one: StateRGB, _ two: StateRGB) -> Double {
        let (l1, a1, b1) = one.lab, (l2, a2, b2) = two.lab
        let c1 = hypot(a1, b1), c2 = hypot(a2, b2), cMean = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + pow(25, 7))))
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) * 180 / .pi; return h < 0 ? h + 360 : h }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 { dhp = h2p - h1p; if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 } }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp * .pi / 360)
        let lMean = (l1 + l2) / 2, cMeanP = (c1p + c2p) / 2
        var hMean = h1p + h2p
        if c1p * c2p != 0 { hMean = abs(h1p - h2p) <= 180 ? (h1p + h2p) / 2 : (h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2) }
        func cosd(_ x: Double) -> Double { cos(x * .pi / 180) }
        let t = 1 - 0.17 * cosd(hMean - 30) + 0.24 * cosd(2 * hMean) + 0.32 * cosd(3 * hMean + 6) - 0.20 * cosd(4 * hMean - 63)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cMeanP, 7) / (pow(cMeanP, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lMean - 50, 2) / sqrt(20 + pow(lMean - 50, 2)), sc = 1 + 0.045 * cMeanP, sh = 1 + 0.015 * cMeanP * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        return sqrt(pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2) + rt * (dCp / sc) * (dHp / sh))
    }
}

@MainActor
enum StateRuleChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let forest = AppThemePalette(theme: .forest), classic = AppThemePalette(theme: .classic)
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        func rgb(_ color: Color, _ appearance: NSAppearance) -> StateRGB {
            var out = StateRGB(r: 0, g: 0, b: 0)
            appearance.performAsCurrentDrawingAppearance {
                if let c = NSColor(color).usingColorSpace(.sRGB) {
                    out = StateRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
                }
            }
            return out
        }
        func rgb(_ color: NSColor, _ appearance: NSAppearance) -> StateRGB { rgb(Color(nsColor: color), appearance) }
        func report(_ name: String, _ on: StateRule.Look, _ off: StateRule.Look) -> String {
            String(format: "%@: mark ΔE %.1f, area ΔE %.1f", name, StateRule.deltaE(on.mark, off.mark), StateRule.deltaE(on.area, off.area))
        }

        // The rule's own samples: the old Forest toggles and current line fail; ΔE itself matches a known value.
        let oldPanel = StateRGB(hex: 0xf8f6ef)
        let oldOn = StateRule.Look(mark: StateRGB(hex: 0x123f32), area: oldPanel), oldOff = StateRule.Look(mark: StateRGB(hex: 0x19221d), area: oldPanel)
        check(!StateRule.tellsApart(oldOn, oldOff), "state rule: the old Forest toggles (#123F32 on / #19221D off, no chip) must fail it (\(report("old", oldOn, oldOff)))")
        let primaryOnPanel = StateRGB(r: 0, g: 0, b: 0, a: 0.85).over(oldPanel)
        check(!StateRule.tellsApart(StateRule.Look(mark: StateRGB(hex: 0x123f32), area: oldPanel), StateRule.Look(mark: primaryOnPanel, area: oldPanel)),
              "state rule: the old Forest current line (accent against the primary text, no chip) must fail it")
        check(abs(StateRule.deltaE(StateRGB(hex: 0x123f32), StateRGB(hex: 0x19221d)) - 13.4) < 0.2, "state rule: CIEDE2000 matches the reference (13.4)")

        // Forest, the palette's values as the shared looks use them (StateMarks.swift; the wiring guard pins the names).
        let panel = rgb(forest.panel, light), window = rgb(forest.window, light)
        let toggleOn = StateRule.Look(mark: rgb(forest.accent, light), area: rgb(forest.onChip, light))
        let toggleOff = StateRule.Look(mark: rgb(forest.secondaryText, light), area: panel)
        check(StateRule.tellsApart(toggleOn, toggleOff), "Forest: an icon toggle's on and off tell apart (\(report("toggle", toggleOn, toggleOff)))")
        check(StateRule.deltaE(rgb(forest.onChip, light), window) >= StateRule.areaMinimum,
              "Forest: the on chip shows on the window colour too (the workbench buttons)")
        let currentOn = StateRule.Look(mark: rgb(forest.accent, light), area: rgb(forest.onChip, light))
        let lineOff = StateRule.Look(mark: rgb(Color.primary, light).over(panel), area: panel)
        let indexOff = StateRule.Look(mark: rgb(Color.secondary, light).over(panel), area: panel)
        check(StateRule.tellsApart(currentOn, lineOff), "Forest: the current line tells apart from the others (\(report("current", currentOn, lineOff)))")
        check(StateRule.tellsApart(currentOn, indexOff), "Forest: the current line's index tells apart (\(report("index", currentOn, indexOff)))")
        check(StateRule.contrast(currentOn.mark, currentOn.area) >= StateRule.textMinimum, "Forest: the current line's text reads on its chip")
        let rowEdge = forest.rowSelectionStroke.map { rgb($0, light) } ?? rgb(forest.rowSelectionFill, light).over(panel)
        let selected = StateRule.Look(mark: rowEdge, area: rowEdge)
        check(StateRule.deltaE(rowEdge, panel) >= StateRule.areaMinimum, "Forest: a selected row shows (\(report("selected", selected, StateRule.Look(mark: panel, area: panel))))")
        check(StateRule.deltaE(rgb(forest.onChip, light), rgb(forest.rowSelectionFill, light).over(panel)) >= StateRule.areaMinimum,
              "Forest: on a row that is selected and current, the current chip still shows")
        // A light fill for the selected row (selectionFill) would melt: the reason the row is outlined in Forest.
        check(StateRule.deltaE(rgb(forest.selectionFill, light), panel) < StateRule.areaMinimum, "Forest: selectionFill alone is too faint for a selected row (why it is outlined)")
        check(forest.highlight == forest.accent && forest.overVideo == .white && forest.overVideoLabel == .black,
              "Forest: selections draw Forest colours, never the macOS accent")

        // Classic, its own colours (AppKit's toggles with the teal tint; the macOS accent: default blue measured).
        for (name, appearance, accent) in [("light", light, StateRGB(hex: 0x007aff)), ("dark", dark, StateRGB(hex: 0x0a84ff))] {
            let back = rgb(NSColor.windowBackgroundColor, appearance)
            let teal = StateRule.Look(mark: rgb(classic.toggleAccent, appearance), area: back)
            for (offName, off) in [("label", rgb(NSColor.labelColor, appearance).over(back)),
                                   ("half label", rgb(NSColor.labelColor.withAlphaComponent(0.5), appearance).over(back))] {
                let offLook = StateRule.Look(mark: off, area: back)
                check(StateRule.tellsApart(teal, offLook), "Classic \(name): a toggle's teal on and \(offName) off tell apart (\(report("toggle", teal, offLook)))")
            }
            let current = StateRule.Look(mark: accent, area: back)
            check(StateRule.tellsApart(current, StateRule.Look(mark: rgb(NSColor.labelColor, appearance).over(back), area: back)),
                  "Classic \(name): the current line tells apart")
            check(StateRule.tellsApart(current, StateRule.Look(mark: rgb(NSColor.secondaryLabelColor, appearance).over(back), area: back)),
                  "Classic \(name): the current line's index tells apart")
            let fill = StateRGB(r: accent.r, g: accent.g, b: accent.b, a: 0.18).over(back)
            check(StateRule.deltaE(fill, back) >= StateRule.areaMinimum, "Classic \(name): a selected row's accent fill shows")
        }
        // Classic keeps what it drew: the accent sites are `Color.accentColor` itself, the workbench chip is the old one.
        check(classic.highlight == Color.accentColor && classic.overVideo == Color.accentColor && classic.overVideoLabel == Color.accentColor
              && classic.rowSelectionFill == Color.accentColor.opacity(0.18) && classic.rowSelectionStroke == nil
              && classic.overVideoGlow == nil && classic.overVideoHollow == .white && classic.onChip == classic.selectionFill
              && classic.selectionStroke == .white, "Classic: every state colour is what it was before")
    }
}

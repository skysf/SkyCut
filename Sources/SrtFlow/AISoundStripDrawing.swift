import CoreGraphics
import CoreText
import Foundation

// MARK: - Drawing the sound strip under a contact sheet (CoreGraphics; MCP-66)
//
// What it does: one AISoundStrip → a picture as wide as the sheet (never narrower than the size's single-frame long side), and the
// sheet with the strip under it as one picture (a look still sends one image). Top to bottom: the #n lane (where each frame of the
// sheet lies: the sheet labels its tiles #1, #2, … in the same order), one row per sound, the ruler. In a row: its name at the top
// left; each pixel column's highest true peak (light) and level (solid) mirrored about the middle on a square-root scale (height =
// √amplitude: half height is about −12 dBFS, a quarter −24, every 12 dB halves it), the peak red above the limiter's ceiling; a blue
// line where a sound starts, labelled with the clip's short id when there is room. White dashed lines run from each #n through the
// rows. The ruler is in timeline seconds; short ticks are frames when a frame is at least 4 pixels wide.
// What it does not do: the numbers (AISoundStrip), the sheet (AIContactSheet), measuring (AISoundStripMeasure).

enum AISoundStripDrawing {
    struct Layout: Equatable {
        var width: Int
        var height: Int
        var unit: Double
        /// The #n lane (CoreGraphics coordinates: origin at the bottom left).
        var marks: CGRect
        /// One per row, the first on top.
        var rows: [CGRect]
        var ruler: CGRect
        /// The line of the #n lane each mark's label sits on (tile order): labels of close frames go on a second or third line.
        var markLines: [Int]
    }

    static let background = CGColor(gray: 0.12, alpha: 1)
    static let rowColor = CGColor(gray: 0.17, alpha: 1)
    static let peakColor = CGColor(red: 0.30, green: 0.52, blue: 0.42, alpha: 1)
    static let levelColor = CGColor(red: 0.60, green: 0.94, blue: 0.70, alpha: 1)
    static let overColor = CGColor(red: 0.96, green: 0.30, blue: 0.24, alpha: 1)
    static let startColor = CGColor(red: 0.33, green: 0.62, blue: 1.00, alpha: 1)
    static let markColor = CGColor(gray: 0.96, alpha: 1)

    /// 1 at the medium sheet's width (1152 pixels).
    static func unit(width: Int) -> Double { min(1.4, max(0.6, Double(width) / 1152)) }

    /// Height for an amplitude (linear, 0…1 of half the row): its square root.
    static func scaled(_ amplitude: Double) -> Double { min(1, max(0, amplitude)).squareRoot() }

    static func layout(_ strip: AISoundStrip, width: Int) -> Layout {
        let unit = unit(width: width)
        let lines = markLines(strip, width: width, font: markFont(unit))
        let lane = (markFont(unit) * 1.5).rounded() * Double((lines.max() ?? 0) + 1)
        let base: Double = strip.rows.count <= 1 ? 88 : strip.rows.count == 2 ? 66 : strip.rows.count == 3 ? 56 : 50
        let rowHeight = (base * unit).rounded()
        let ruler = max(22, (24 * unit).rounded())
        let gap = (8 * unit).rounded()
        let height = gap + lane + rowHeight * Double(strip.rows.count) + ruler
        let rows = strip.rows.indices.map { index in
            CGRect(x: 0, y: height - gap - lane - rowHeight * Double(index + 1), width: Double(width), height: rowHeight)
        }
        return Layout(width: width, height: Int(height), unit: unit,
                      marks: CGRect(x: 0, y: height - gap - lane, width: Double(width), height: lane),
                      rows: rows, ruler: CGRect(x: 0, y: 0, width: Double(width), height: ruler), markLines: lines)
    }

    /// The sheet with the strip under it: one picture as wide as the wider of the two (the sheet centred).
    static func stack(_ sheet: CGImage, with strip: AISoundStrip, minimumWidth: Int) -> CGImage? {
        let width = max(sheet.width, minimumWidth)
        guard let below = draw(strip, width: width), let context = context(width: width, height: sheet.height + below.height) else {
            return nil
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: sheet.height + below.height))
        context.draw(below, in: CGRect(x: 0, y: 0, width: width, height: below.height))
        context.draw(sheet, in: CGRect(x: (width - sheet.width) / 2, y: below.height, width: sheet.width, height: sheet.height))
        return context.makeImage()
    }

    /// The strip alone, `width` pixels wide.
    static func draw(_ strip: AISoundStrip, width: Int) -> CGImage? {
        let layout = layout(strip, width: width)
        guard width > 0, layout.height > 0, let context = context(width: width, height: layout.height) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: layout.height))
        for (row, rect) in zip(strip.rows, layout.rows) { drawRow(row, in: rect, strip: strip, unit: layout.unit, context: context) }
        drawRuler(strip, layout: layout, context: context)
        drawMarks(strip, layout: layout, context: context)
        return context.makeImage()
    }

    /// How to read the strip, for the result's `image` note.
    static func reading(_ strip: AISoundStrip) -> String {
        let seconds = { (value: Double) in String(format: "%.2f", value) }
        return "Below the pictures: the timeline's sound from \(seconds(strip.from)) to \(seconds(strip.to)) s, one row each for "
            + strip.rows.map(\.name).joined(separator: ", ")
            + (strip.afterLimiter ? " (after the export limiter, as delivered)" : " (before the export limiter, as listen mix=true)")
            + ". Height is the square root of the level: half height is about -12 dBFS, a quarter about -24. Light = each frame's "
            + "true peak, solid = its level, red = above the -1 dBTP limiter ceiling. Blue lines = where a sound starts (the clip's "
            + "id; sound.starts lists them). White dashed lines = frame #n of the sheet. The ruler is in timeline seconds; short "
            + "ticks are frames."
    }

    // MARK: Rows

    private static func drawRow(_ row: AISoundStrip.Row, in rect: CGRect, strip: AISoundStrip, unit: Double, context: CGContext) {
        context.setFillColor(rowColor)
        context.fill(rect.insetBy(dx: 0, dy: 1))
        let half = rect.height / 2 - 3 * unit
        for (x, column) in strip.columns(of: row, width: Int(rect.width)).enumerated() {
            guard let column else { continue }
            let peak = scaled(Double(column.peak)) * half
            let level = scaled(column.meanSquare.squareRoot()) * half
            context.setFillColor(column.peak > strip.ceiling ? overColor : peakColor)
            context.fill(CGRect(x: Double(x), y: rect.midY - peak, width: 1, height: peak * 2))
            context.setFillColor(levelColor)
            context.fill(CGRect(x: Double(x), y: rect.midY - level, width: 1, height: level * 2))
        }
        context.setFillColor(CGColor(gray: 0.32, alpha: 1))
        context.fill(CGRect(x: 0, y: rect.midY - 0.5, width: rect.width, height: 1))
        label(row.name, at: CGPoint(x: 4 * unit, y: rect.maxY - 4 * unit), size: textSize(12, unit),
              color: CGColor(gray: 1, alpha: 1), box: CGColor(gray: 0, alpha: 0.6), context: context, alignTop: true)
        // Start labels sit at the bottom of the row (the name is at the top), each where it does not touch the one before.
        var lastEnd = -Double.infinity
        let startSize = textSize(10.5, unit)
        context.setFillColor(startColor)
        for start in row.starts {
            // Lines sit on the middle of the pixel column that holds their time (the column the levels draw that time in).
            let x = strip.x(of: start.time, width: Int(rect.width)).rounded(.down) + 0.5
            let thickness = max(1, 1.5 * unit)
            context.fill(CGRect(x: x - thickness / 2, y: rect.minY + 1, width: thickness, height: rect.height - 2))
            let room = CTLineGetBoundsWithOptions(line(start.clip, size: startSize, color: startColor), .useOpticalBounds).width + startSize
            guard x + 3 * unit > lastEnd + 2 * unit, x + 3 * unit + room <= rect.width else { continue }
            let drawn = label(start.clip, at: CGPoint(x: x + 3 * unit, y: rect.minY + 4 * unit), size: startSize, color: startColor,
                              box: CGColor(gray: 0, alpha: 0.55), context: context, alignTop: false)
            lastEnd = drawn.maxX
            context.setFillColor(startColor)
        }
    }

    // MARK: Ruler and marks

    static let rulerSteps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]

    /// The labelled step: the finest whose labels are at least 64 units apart.
    static func rulerStep(span: Double, width: Int) -> Double {
        let perSecond = Double(width) / max(1e-9, span)
        return rulerSteps.first { $0 * perSecond >= 64 * unit(width: width) } ?? rulerSteps[rulerSteps.count - 1]
    }

    private static func drawRuler(_ strip: AISoundStrip, layout: Layout, context: CGContext) {
        let unit = layout.unit, top = layout.ruler.maxY
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: top - 1, width: layout.ruler.width, height: 1))
        let frame = 1 / Double(strip.grid.fps)
        if Double(layout.width) * frame / max(1e-9, strip.to - strip.from) >= 4 {
            context.setFillColor(CGColor(gray: 0.42, alpha: 1))
            let first = strip.grid.frame(containing: strip.from)
            for index in first ... max(first, strip.grid.frame(endingAt: strip.to)) {
                let x = strip.x(of: strip.grid.seconds(ofFrame: index), width: layout.width).rounded(.down)
                if x >= 0, x < Double(layout.width) { context.fill(CGRect(x: x, y: top - 4 * unit, width: 1, height: 3 * unit)) }
            }
        }
        let step = rulerStep(span: strip.to - strip.from, width: layout.width)
        let format = step >= 1 ? "%.0fs" : "%.1fs"
        var time = (strip.from / step).rounded(.up) * step
        while time <= strip.to + 1e-9 {
            let x = strip.x(of: time, width: layout.width)
            context.setFillColor(CGColor(gray: 0.75, alpha: 1))
            context.fill(CGRect(x: x.rounded(.down), y: top - 7 * unit, width: 1, height: 6 * unit))
            let text = String(format: format, time)
            let half = CTLineGetBoundsWithOptions(line(text, size: textSize(11, unit), color: markColor), .useOpticalBounds).width / 2
            let left = min(max(1, x - half), Double(layout.width) - 2 * half - 1)
            label(text, at: CGPoint(x: left, y: 2 * unit), size: textSize(11, unit), color: CGColor(gray: 0.85, alpha: 1), box: nil,
                  context: context, alignTop: false)
            time += step
        }
    }

    private static func markFont(_ unit: Double) -> Double { max(12, 13 * unit) }

    /// Text sizes follow the width but stay legible on a narrow strip (a single tall frame, a small sheet).
    private static func textSize(_ base: Double, _ unit: Double) -> Double { max(10.5, base * unit) }

    /// The #n labels' lines: in time order, each on the first line where it does not touch a label already there (three at most).
    static func markLines(_ strip: AISoundStrip, width: Int, font: Double) -> [Int] {
        var lines = Array(repeating: 0, count: strip.marks.count)
        var taken: [[ClosedRange<Double>]] = [[], [], []]
        for index in strip.marks.indices.sorted(by: { strip.marks[$0] < strip.marks[$1] }) {
            let x = strip.x(of: strip.marks[index], width: width)
            let half = CTLineGetBoundsWithOptions(line("#\(index + 1)", size: font, color: markColor), .useOpticalBounds).width / 2
                + font * 0.5
            let span = (x - half)...(x + half)
            let free = taken.indices.first { taken[$0].allSatisfy { !$0.overlaps(span) } } ?? 0
            lines[index] = free
            taken[free].append(span)
        }
        return lines
    }

    private static func drawMarks(_ strip: AISoundStrip, layout: Layout, context: CGContext) {
        let unit = layout.unit
        let lineHeight = (markFont(unit) * 1.5).rounded()
        context.saveGState()
        context.setStrokeColor(markColor)
        context.setLineWidth(max(1, 1.2 * unit))
        context.setLineDash(phase: 0, lengths: [5 * unit, 4 * unit])
        for mark in strip.marks {
            let x = strip.x(of: mark, width: layout.width).rounded(.down) + 0.5
            context.move(to: CGPoint(x: x, y: layout.ruler.maxY))
            context.addLine(to: CGPoint(x: x, y: layout.marks.minY + lineHeight * 0.2))
        }
        context.strokePath()
        context.restoreGState()
        for (index, mark) in strip.marks.enumerated() {
            let text = "#\(index + 1)"
            let x = strip.x(of: mark, width: layout.width)
            let half = CTLineGetBoundsWithOptions(line(text, size: markFont(unit), color: markColor), .useOpticalBounds).width / 2
                + markFont(unit) * 0.3
            let left = min(max(1, x - half), Double(layout.width) - 2 * half - 1)
            let top = layout.marks.maxY - lineHeight * Double(layout.markLines[index]) - 2 * unit
            label(text, at: CGPoint(x: left, y: top), size: markFont(unit), color: markColor, box: CGColor(gray: 0, alpha: 0.65),
                  context: context, alignTop: true)
        }
    }

    // MARK: Text

    private static func line(_ text: String, size: Double, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Draws `text` (on a rounded box when `box` is given) with its box's top-left (`alignTop`) or bottom-left at `point`.
    @discardableResult
    private static func label(
        _ text: String, at point: CGPoint, size: Double, color: CGColor, box: CGColor?, context: CGContext, alignTop: Bool
    ) -> CGRect {
        let drawn = line(text, size: size, color: color)
        let bounds = CTLineGetBoundsWithOptions(drawn, .useOpticalBounds)
        let padding = size * 0.3
        let height = bounds.height + padding * 2
        let rect = CGRect(x: point.x, y: alignTop ? point.y - height : point.y, width: bounds.width + padding * 2, height: height)
        if let box {
            context.setFillColor(box)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: padding, cornerHeight: padding, transform: nil))
            context.fillPath()
        }
        context.textPosition = CGPoint(x: rect.minX + padding - bounds.minX, y: rect.minY + padding - bounds.minY)
        CTLineDraw(drawn, context)
        return rect
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}

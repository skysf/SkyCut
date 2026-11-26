// The DMG install background, the one source of its artwork: system fonts with AppKit / Core Text,
// written as 1x and 2x PNGs of one logical size (scripts/build-dmg.sh joins them into the Retina TIFF).
// It doesn't draw the App / Applications icons (the real files Finder shows) or make the window layout
// (packaging/dmg/DS_Store); between the icons it draws the drag hint, with faded copies of SkyCut's icon
// (the 1024 px PNG scripts/make-icon.swift makes, so the hint follows the app's icon).
// Step 1 is in six languages, English first; step 2 names the one guide link.
// Since 2026-11-26 builds are notarized and open directly, so the old step 2 (System Settings › Open
// Anyway) is gone. Every run carries its language, so Core Text draws Traditional Chinese and Japanese
// in their own faces (PingFang TC, Hiragino) instead of falling back to Simplified Chinese glyphs.
import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: swift scripts/dmg/make-background.swift <output-directory> <icon-1024.png>\n", stderr)
    exit(2)
}
let output = arguments[1]
guard let icon = NSImage(contentsOfFile: arguments[2]) else {
    fputs("Cannot read SkyCut's icon at \(arguments[2])\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

// The canvas is a contract: the Finder window is this plus 88 pt for its title, path and status bars
// (scripts/dmg/make-layout.py), and scripts/dmg/check-background.swift pins both pixel sizes.
let width = 760
let height = 510
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let paper = color(0xf3f0e8)
let forest = color(0x123f32)
let ink = color(0x19221d)
let secondary = color(0x505b4a)
let separator = color(0xa3a897)

// The copy. The Applications folder's name is the system's own string in each language (macOS 26.5.2).
struct Line { let language: String; let text: String }
let steps: [[Line]] = [
    [
        Line(language: "en", text: "Drag SkyCut to Applications"),
        Line(language: "zh-Hans", text: "把 SkyCut 拖到「应用程序」"),
        Line(language: "zh-Hant", text: "將 SkyCut 拖到「應用程式」"),
        Line(language: "es", text: "Arrastra SkyCut a Aplicaciones"),
        Line(language: "ja", text: "SkyCut を「アプリケーション」にドラッグ"),
        Line(language: "ru", text: "Перетащите SkyCut в «Программы»"),
    ],
]
let guideLabel = [("en", "Video guide"), ("zh-Hans", "视频教程"), ("zh-Hant", "影片教學"),
                  ("es", "Videotutorial"), ("ja", "動画ガイド"), ("ru", "Видеоинструкция")]
let guideLink = "www.skycut.app/docs"

// The steps are laid out by baseline (top-left points), so lines in different scripts share one rhythm:
// every line is 14 pt regular on a 20 pt pitch, and English sits 4 pt further from the line below it.
let size: CGFloat = 14
let textX: CGFloat = 82
let pitch: CGFloat = 20
let englishGap: CGFloat = 4
let stepGap: CGFloat = 34

typealias Run = (language: String, text: String, color: NSColor)
let languageKey = NSAttributedString.Key(kCTLanguageAttributeName as String)
let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

func ctLine(_ runs: [Run], size: CGFloat, weight: NSFont.Weight) -> CTLine {
    let string = NSMutableAttributedString()
    for run in runs {
        string.append(NSAttributedString(string: run.text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            colorKey: run.color.cgColor, languageKey: run.language,
        ]))
    }
    return CTLineCreateWithAttributedString(string)
}

// Draws one line with its baseline at `baseline`; copy that would leave the canvas stops the build.
func line(_ runs: [Run], x: CGFloat, baseline: CGFloat, weight: NSFont.Weight = .regular) {
    let line = ctLine(runs, size: size, weight: weight)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let text = runs.map(\.text).joined()
    precondition(x + lineWidth <= CGFloat(width) - 36, "DMG copy exceeds the canvas: \(text)")
    precondition(baseline + descent <= CGFloat(height) - 24, "DMG copy runs off the bottom: \(text)")
    let context = NSGraphicsContext.current!.cgContext
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: CGFloat(height) - baseline)
    CTLineDraw(line, context)
}

// A step's number badge, centred on the cap height of the step's first line.
func badge(_ number: Int, baseline: CGFloat) {
    let centre = baseline - NSFont.systemFont(ofSize: size).capHeight / 2
    forest.setFill()
    NSBezierPath(ovalIn: NSRect(x: 40, y: CGFloat(height) - centre - 13, width: 26, height: 26)).fill()
    let digit = ctLine([("en", "\(number)", paper)], size: 15, weight: .semibold)
    let digitWidth = CGFloat(CTLineGetTypographicBounds(digit, nil, nil, nil))
    let digitCap = NSFont.systemFont(ofSize: 15, weight: .semibold).capHeight
    let context = NSGraphicsContext.current!.cgContext
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 53 - digitWidth / 2, y: CGFloat(height) - centre - digitCap / 2)
    CTLineDraw(digit, context)
}

// The icon band. Finder draws the real icons at (200, 164) and (560, 164) (the template's Iloc), and a
// selected one on a 144 pt grey square with its label in a pill below it (down to y 258). Nothing is drawn
// there, so Finder's selection always sits on plain paper: the halos that sat behind the icons until
// 2026-11-26 clashed with it. The drag hint lives between the icons (x 284–458); check-background.swift
// pins both, and probes only the hint's own ink (pointer, arrow), never the icon copies.
let iconY: CGFloat = 164

// Strobe frames of the drag (the user's pick, 2026-11-26): SkyCut's icon three times, fading in towards
// Applications, a pointer holding the last copy, then the arrowhead on a short shaft.
func dragHint() {
    for (centreX, alpha) in [(306, 0.12), (348, 0.25), (390, 0.45)] as [(CGFloat, CGFloat)] {
        ghost(centreX: centreX, side: 44, alpha: alpha)
    }
    pointer(tipX: 394, tipY: iconY + 4)
    arrow(from: 430, to: 456)
}

// A faded copy of SkyCut's icon whose rounded square is `side` pt (make-icon.swift draws it on the 824 px
// grid of the 1024 px canvas).
func ghost(centreX: CGFloat, side: CGFloat, alpha: CGFloat) {
    let frame = side * 1024 / 824
    NSGraphicsContext.current!.imageInterpolation = .high
    icon.draw(in: NSRect(x: centreX - frame / 2, y: CGFloat(height) - iconY - frame / 2, width: frame, height: frame),
              from: .zero, operation: .sourceOver, fraction: alpha)
}

// A black pointer with a white edge and a soft shadow, like the system's. Its outline was traced once from
// macOS 26's arrow cursor, in points from the tip (y down): a fixed shape, so the build needs no cursor image.
let pointerOutline: [(CGFloat, CGFloat)] = [
    (0, 0), (8.25, 7.95), (8.25, 8.65), (7.85, 8.95), (4.95, 9.05), (6.85, 13.65), (6.15, 14.65),
    (5.45, 14.65), (4.85, 14.15), (2.95, 9.75), (0.85, 11.55), (0, 11.15),
]

func pointer(tipX: CGFloat, tipY: CGFloat) {
    let path = NSBezierPath()
    for (index, (x, y)) in pointerOutline.enumerated() {
        let point = NSPoint(x: tipX + x, y: CGFloat(height) - tipY - y)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = 2
    // The white edge (1 pt outside the black) and its shadow; shadow sizes are in device pixels, so scale them.
    let context = NSGraphicsContext.current!.cgContext
    let scale = context.userSpaceToDeviceSpaceTransform.a
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -scale), blur: 2 * scale,
                      color: NSColor(white: 0, alpha: 0.35).cgColor)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.set()
    path.fill()
    path.stroke()
    context.endTransparencyLayer()
    context.restoreGState()
    NSColor.black.setFill()
    path.fill()
}

// An arrow along the icons' centre line: a 3 pt forest stroke with round ends and a 16 pt head.
func arrow(from startX: CGFloat, to tipX: CGFloat) {
    let y = CGFloat(height) - iconY
    let path = NSBezierPath()
    path.move(to: NSPoint(x: startX, y: y))
    path.line(to: NSPoint(x: tipX, y: y))
    path.move(to: NSPoint(x: tipX - 16, y: y + 16))
    path.line(to: NSPoint(x: tipX, y: y))
    path.line(to: NSPoint(x: tipX - 16, y: y - 16))
    path.lineWidth = 3
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    forest.setStroke()
    path.stroke()
}

func artwork() {
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let wordmark = NSAttributedString(string: "SkyCut", attributes: [
        .font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: forest,
    ])
    wordmark.draw(at: NSPoint(x: 40, y: CGFloat(height) - 28 - wordmark.size().height))
    dragHint()

    color(0xd7d5c8).setFill()
    NSRect(x: 40, y: height - 280, width: 680, height: 1).fill()
    var baseline: CGFloat = 316
    for (index, lines) in steps.enumerated() {
        badge(index + 1, baseline: baseline)
        for (row, entry) in lines.enumerated() {
            line([(entry.language, entry.text, entry.language == "en" ? ink : secondary)],
                 x: textX, baseline: baseline)
            if row < lines.count - 1 { baseline += pitch + (row == 0 ? englishGap : 0) }
        }
        baseline += stepGap
    }
    badge(steps.count + 1, baseline: baseline)
    var label: [Run] = []
    for (language, word) in guideLabel {
        if !label.isEmpty { label.append(("en", "  ·  ", separator)) }
        label.append((language, word, language == "en" ? ink : secondary))
    }
    line(label, x: textX, baseline: baseline)
    line([("en", guideLink, forest)], x: textX, baseline: baseline + pitch + englishGap, weight: .medium)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
        pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    artwork()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/" + name))
    print("wrote \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(bitmap.size)")
}

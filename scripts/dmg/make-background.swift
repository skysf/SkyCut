// The DMG install background, the one source of its artwork: system fonts with AppKit / Core Text,
// written as 1x and 2x PNGs of one logical size (scripts/build-dmg.sh joins them into the Retina TIFF).
// It doesn't draw the App / Applications icons (the real files Finder shows) or make the window layout
// (packaging/dmg/DS_Store). Steps 1 and 2 are in six languages, English first; step 3 names the one
// guide link. Every run carries its language, so Core Text draws Traditional Chinese and Japanese in
// their own faces (PingFang TC, Hiragino) instead of falling back to Simplified Chinese glyphs.
import AppKit
import CoreText

let output = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : ""
guard !output.isEmpty else {
    fputs("Usage: swift scripts/dmg/make-background.swift <output-directory>\n", stderr)
    exit(2)
}
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

// The canvas is a contract: the Finder window is this plus 88 pt for its title, path and status bars
// (scripts/dmg/make-layout.py), and scripts/dmg/check-background.swift pins both pixel sizes.
let width = 760
let height = 688
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

// The copy. macOS names are the system's own strings (macOS 26.5.2): the Applications folder, System
// Settings, Privacy & Security and its Open Anyway button. Spanish gives Spain's names, then Latin
// America's (es_419) as the alternative; Russian is too wide for one line, so its path hangs below.
struct Line { let language: String; let text: String; var indent: CGFloat = 0 }
let hang: CGFloat = 16
let steps: [[Line]] = [
    [
        Line(language: "en", text: "Drag SkyCut to Applications"),
        Line(language: "zh-Hans", text: "把 SkyCut 拖到「应用程序」"),
        Line(language: "zh-Hant", text: "將 SkyCut 拖到「應用程式」"),
        Line(language: "es", text: "Arrastra SkyCut a Aplicaciones"),
        Line(language: "ja", text: "SkyCut を「アプリケーション」にドラッグ"),
        Line(language: "ru", text: "Перетащите SkyCut в «Программы»"),
    ],
    [
        Line(language: "en", text: "Blocked on first open? System Settings › Privacy & Security › Open Anyway"),
        Line(language: "zh-Hans", text: "第一次打开被拦下：系统设置 › 隐私与安全性 › 仍要打开"),
        Line(language: "zh-Hant", text: "第一次打開被擋下：系統設定 › 隱私權與安全性 › 強制打開"),
        Line(language: "es", text: "¿Bloqueado al abrir? Ajustes del Sistema › Privacidad y seguridad › Abrir igualmente"),
        Line(language: "es-419", text: "o: Configuración del Sistema › Privacidad y seguridad › Abrir de todos modos",
             indent: hang),
        Line(language: "ja", text: "初回起動がブロックされたら：システム設定 › プライバシーとセキュリティ › このまま開く"),
        Line(language: "ru", text: "Заблокировано при запуске?"),
        Line(language: "ru", text: "Системные настройки › Конфиденциальность и безопасность › Все равно открыть",
             indent: hang),
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

func artwork() {
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let wordmark = NSAttributedString(string: "SkyCut", attributes: [
        .font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: forest,
    ])
    wordmark.draw(at: NSPoint(x: 40, y: CGFloat(height) - 28 - wordmark.size().height))

    // 真实图标中心在 (200, 164)、(560, 164)，与模板的 Iloc 一致。
    color(0xe6e8dc).setFill()
    for centerX in [200, 560] {
        NSBezierPath(ovalIn: NSRect(x: centerX - 79, y: height - 164 - 79,
                                  width: 158, height: 158)).fill()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 321, y: height - 164))
    arrow.line(to: NSPoint(x: 439, y: height - 164))
    arrow.move(to: NSPoint(x: 423, y: height - 148))
    arrow.line(to: NSPoint(x: 439, y: height - 164))
    arrow.line(to: NSPoint(x: 423, y: height - 180))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    forest.setStroke()
    arrow.stroke()

    color(0xd7d5c8).setFill()
    NSRect(x: 40, y: height - 280, width: 680, height: 1).fill()
    var baseline: CGFloat = 316
    for (index, lines) in steps.enumerated() {
        badge(index + 1, baseline: baseline)
        for (row, entry) in lines.enumerated() {
            line([(entry.language, entry.text, entry.language == "en" ? ink : secondary)],
                 x: textX + entry.indent, baseline: baseline)
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

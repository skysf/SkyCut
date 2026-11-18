import CoreGraphics
import Foundation
import SrtFlowMCPKit

// The sound strip under a look's contact sheet (MCP-66), pure parts: which seconds it spans, which frames each pixel column shows,
// what the AI reads (each row's loudest frame and true peak, the starts), and the drawing itself read back pixel by pixel (the level
// at its square-root height, the peak red above the ceiling, a blue line at a start, a dashed white line at each #n, the strip under
// the sheet). The real path (look on a project, the engine's render) is in checks/LookJobs/LookSoundChecks.swift.
// Called from runLookChecks (checks/MCP/LookChecks.swift); built by scripts/check-mcp.sh.

func runLookSoundChecks() {
    checkStripWindow()
    checkStripColumns()
    checkStripSummary()
    checkStripDrawing()
}

private let grid24 = MixFrameGrid(fps: 24)

private func checkStripWindow() {
    let frame = 1.0 / 24
    let single = AISoundStrip.window(times: [3], duration: 10, grid: grid24)
    checkEqual(single?.lowerBound, 2, "one frame: a second before it")
    check(abs((single?.upperBound ?? 0) - (4 + frame)) < 1e-9, "one frame: a second after its own frame")
    let five = AISoundStrip.window(times: [29, 28, 30, 28.5, 29.5], duration: 60, grid: grid24)
    checkEqual(five?.lowerBound, 27.75, "frames 0.5 s apart: half the spacing before the first (in any order)")
    check(abs((five?.upperBound ?? 0) - (30.25 + frame)) < 1e-9, "and half the spacing after the last frame's end")
    let edge = AISoundStrip.window(times: [0, 0.1], duration: 0.5, grid: MixFrameGrid(fps: 30))
    checkEqual(edge?.lowerBound, 0, "the window stays inside the timeline at its start")
    check(abs((edge?.upperBound ?? 0) - (0.1 + 1.0 / 30 + 0.05)) < 1e-9, "room is half the spacing when that is more than a frame")
    let close = AISoundStrip.window(times: [5, 5.01], duration: 60, grid: grid24)
    check(abs((close?.lowerBound ?? 0) - (5 - frame)) < 1e-9, "frames closer than a frame still get a frame of room")
    let far = AISoundStrip.window(times: [1, 40], duration: 30.5, grid: grid24)
    checkEqual(far?.lowerBound, 0, "room is at most a second (and the start is clamped)")
    checkEqual(far?.upperBound, 30.5, "the end is clamped to the timeline")
    check(AISoundStrip.window(times: [], duration: 10, grid: grid24) == nil, "no frames: no window")
    let covered = AISoundStrip.frames(of: 27.75...(30.25 + frame), grid: grid24, total: 24 * 60)
    checkEqual(covered, 666..<727, "the frames a window covers: the one holding its start to the one holding its end")
    checkEqual(AISoundStrip.frames(of: 0...100, grid: grid24, total: 48), 0..<48, "never past the timeline's last frame")
}

/// One second at 24 fps: quiet frames, frame 12 loud (−6 dBFS level, peak 0.9), frame 20 over the ceiling.
private func strip(starts: [AISoundStrip.Start] = [], marks: [Double] = []) -> AISoundStrip {
    var levels = Array(repeating: AISoundStrip.Level(meanSquare: 1e-4, peak: 0.02), count: 24)
    levels[12] = .init(meanSquare: 0.25, peak: 0.9)
    levels[20] = .init(meanSquare: 0.04, peak: 1.2)
    var strip = AISoundStrip(grid: grid24, firstFrame: 0, from: 0, to: 1,
                             rows: [.init(name: "mix", levels: levels, starts: starts)], afterLimiter: false, ceiling: 0.891)
    strip.marks = marks
    return strip
}

private func checkStripColumns() {
    let wide = strip().columns(of: strip().rows[0], width: 240)
    checkEqual(wide.count, 240, "one column per pixel")
    checkEqual(wide[125], .init(meanSquare: 0.25, peak: 0.9), "ten pixels a frame: the loud frame's own column")
    checkEqual(wide[115], .init(meanSquare: 1e-4, peak: 0.02), "the quiet frame before it")
    let narrow = strip().columns(of: strip().rows[0], width: 12)
    let pair = narrow[6]
    check(pair.map { abs($0.meanSquare - (0.25 + 1e-4) / 2) < 1e-12 && $0.peak == 0.9 } == true,
          "two frames a pixel: their mean level and their higher peak (\(String(describing: pair)))")
    var short = strip()
    short.rows[0].levels = Array(short.rows[0].levels.prefix(12))
    let columns = short.columns(of: short.rows[0], width: 24)
    check(columns[5] != nil && columns[20] == nil, "no measured frame under a column: nothing drawn there")
    checkEqual(strip().x(of: 0.5, width: 240), 120, "a time's place on the picture")
}

private func checkStripSummary() {
    let starts = [AISoundStrip.Start(time: 0.25, clip: "c1", track: "A1", name: "hit.wav"),
                  AISoundStrip.Start(time: 0.75, clip: "c2", track: "A2", name: "rise.wav")]
    var two = strip(starts: starts)
    two.rows.append(.init(name: "A1", levels: Array(repeating: .init(meanSquare: 0, peak: 0), count: 24), starts: [starts[0]]))
    let json = two.json
    let rows = json["rows"]?.arrayValue ?? []
    checkEqual(rows.first?["row"]?.stringValue, "mix", "rows in the order drawn")
    checkEqual(rows.first?["loudest_at"]?.doubleValue, 0.5, "loudest_at is the start of the loudest frame (as listen mix=true)")
    checkEqual(rows.first?["peak_db"]?.doubleValue, (TruePeak.decibels(1.2) * 10).rounded() / 10, "peak_db is the highest true peak, to a tenth")
    checkEqual(rows.last?["silent"]?.boolValue, true, "a silent row says so instead of a loudest frame")
    let listed = json["starts"]?.arrayValue ?? []
    checkEqual(listed.compactMap { $0["clip"]?.stringValue }, ["c1", "c2"], "every start once, in time order (one shows in two rows)")
    checkEqual(listed.first?["at"]?.doubleValue, 0.25, "a start's time")
    checkEqual(json["levels"]?.stringValue?.hasPrefix("before the export limiter"), true, "says which side of the limiter it is")
    let many = strip(starts: (0..<30).map { .init(time: Double($0) / 30, clip: "c\($0)", track: "A1", name: "s") })
    checkEqual(many.json["starts"]?.arrayValue?.count, AISoundStrip.maxListedStarts, "at most \(AISoundStrip.maxListedStarts) starts listed")
    checkEqual(many.json["more_starts"]?.doubleValue, 6, "the rest are counted")
}

/// The picture as RGBA bytes (row 0 at the top).
private func pixels(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8]) {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return (image.width, image.height, bytes)
}

private func checkStripDrawing() {
    checkEqual(AISoundStripDrawing.scaled(0.25), 0.5, "square-root scale: a quarter of full scale (-12 dBFS) is half height")
    checkEqual(AISoundStripDrawing.scaled(1.5), 1, "over full scale is drawn at full height")
    checkEqual(AISoundStripDrawing.rulerStep(span: 2, width: 1152), 0.2, "ruler labels at least 64 pixels apart")
    let marked = strip(starts: [.init(time: 0.75, clip: "c2", track: "A2", name: "rise.wav")], marks: [0.25, 0.5])
    let layout = AISoundStripDrawing.layout(marked, width: 1152)
    checkEqual(layout.height, 8 + 20 + 88 + 24, "one row at the medium width: gap, #n lane, row, ruler")
    checkEqual(layout.markLines, [0, 0], "marks far apart share the #n line")
    var close = marked
    close.marks = [0.5, 0.51]
    checkEqual(AISoundStripDrawing.layout(close, width: 1152).markLines, [0, 1], "marks closer than their labels: the second label goes below")
    checkEqual(AISoundStripDrawing.layout(close, width: 1152).height, layout.height + 20, "and the #n lane grows by a line")
    guard let image = AISoundStripDrawing.draw(marked, width: 1152) else { return check(false, "the strip draws") }
    let (width, height, bytes) = pixels(image)
    checkEqual(width, 1152, "the strip is as wide as asked")
    checkEqual(height, layout.height, "and as high as its layout")
    func rgb(_ x: Int, _ yFromTop: Int) -> (Int, Int, Int) {
        let index = (yFromTop * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
    let row = layout.rows[0]
    let middle = height - Int(row.midY)
    let half = Int(row.height / 2 - 3)
    // −6 dBFS level (0.5 amplitude): √0.5 ≈ 0.71 of half the row, solid green; a quiet frame there is the row's background.
    let levelReach = Int(0.7 * Double(half)) - 2
    let loudX = Int(marked.x(of: 12.5 / 24, width: 1152)), quietX = Int(marked.x(of: 3.5 / 24, width: 1152))
    let loud = rgb(loudX, middle - levelReach), quiet = rgb(quietX, middle - levelReach)
    check(loud.1 > 200 && loud.0 < 200, "the loud frame's level reaches √amplitude of the height in the level color (\(loud))")
    check(quiet.1 < 80, "a quiet frame does not reach that high (\(quiet))")
    let overX = Int(marked.x(of: 20.5 / 24, width: 1152))
    let over = rgb(overX, middle - half + 2)
    check(over.0 > 200 && over.1 < 120, "a peak above the ceiling is red at the top of its column (\(over))")
    let startX = Int(marked.x(of: 0.75, width: 1152).rounded(.down))
    let start = rgb(startX, middle + half / 2)
    check(start.2 > 200 && start.0 < 150, "a blue line where a sound starts, on the column holding its time (\(start))")
    let markX = Int(marked.x(of: 0.25, width: 1152).rounded(.down))
    let white = (Int(row.minY) ..< Int(row.maxY)).map { rgb(markX, height - 1 - $0) }.filter { $0.0 > 220 && $0.1 > 220 && $0.2 > 220 }
    check(white.count > 10, "a dashed white line through the row at frame #1 (\(white.count) white pixels)")
    guard let sheet = solidSheet(432, 768), let stacked = AISoundStripDrawing.stack(sheet, with: marked, minimumWidth: 768) else {
        return check(false, "the sheet and the strip stack")
    }
    checkEqual(stacked.width, 768, "a narrow sheet: the picture is as wide as the size's long side")
    checkEqual(stacked.height, 768 + AISoundStripDrawing.layout(marked, width: 768).height, "the strip goes under the sheet")
    let reading = AISoundStripDrawing.reading(marked)
    check(reading.contains("0.00 to 1.00 s") && reading.contains("mix") && reading.contains("half height is about -12 dBFS"),
          "the image note says which seconds, which rows and how to read the height")
}

private func solidSheet(_ width: Int, _ height: Int) -> CGImage? {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
}

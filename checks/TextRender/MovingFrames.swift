import CoreGraphics
import Foundation
import SrtFlowCore

// Group 20: every exported frame of a moving text / shape is the frame for its own time — none repeated, none a frame
// late, none missing — at 24, 30 and 60 fps (docs/bugfixes/2026-11-17-overlay-export-repeats-a-frame.md).
//
// The scene hits each way it went wrong before (one export per frame rate):
//   · titles wiping in from 0.5 s and 9.5 s (on the frame grid): `from + k / fps` times fps lands a hair below an integer
//     and the old floor drew the previous frame — at 30 fps frames 24 and 25 identical, frame 26 caught up;
//   · a shape wiping in from 3.36 s (off the grid, more than half a frame past it at 24 / 30 / 60): `-itsoffset` rounded the
//     sequence to the nearest frame while the drawing used the frame below, so the whole entrance came a frame late;
//   · the main track has cuts and crossfades: after them the frame timestamps sit microseconds before or after the grid,
//     an overlay frame placed exactly on the grid lost to the one before (30 fps after a crossfade: every third frame
//     repeated), and a still square starting on the grid at 7.2 s lost its first frame (`gte(t, 7.2)`, t = 7.199999999999999);
//   · a title's middle still was drawn for the frame below the end of its entrance, before the wipe had finished
//     (30 fps: the right edge of the plate missing for the whole middle).
// Each frame is measured where the overlays are (a horizontal strip per band): how many columns are lit. The expected
// count comes from the renderers the preview uses, drawn for the frame's own time (`n / fps`) and not through any export
// code. A repeated, late or missing frame is off by a whole frame of the sweep (6 px or more at 60 fps); codec blur moves
// the count by a pixel or two.

private struct MovingStrip {
    var name: String
    var y: Int
    var height = 10
}

func checkMovingOverlayFrames() async {
    checkFrameGridMath()
    let canvas = CGSize(width: 640, height: 360)
    guard let source = try? await makeSolidVideo(white: 0, seconds: 30, name: "moving-black.mp4", size: canvas) else {
        check(false, "moving overlays: could not make the source video")
        return
    }
    // Each strip runs through the middle of one band and clear of the others.
    let strips = [MovingStrip(name: "top title", y: 53), MovingStrip(name: "shape + square", y: 175),
                  MovingStrip(name: "bottom title", y: 297)]
    for rate in [ProjectFrameRate.fps24, .fps30, .fps60] {
        let state = movingScene(rate, source: source, canvas: canvas)
        guard let url = await export(state, name: "moving-\(rate.fps).mp4") else { continue }
        for strip in strips {
            checkStrip(strip, in: url, state: state, rate: rate, canvas: canvas)
        }
    }
}

/// The frame-number rule itself (`FrameGrid`): exact frame times and sums like `0.5 + k / 30` land on their own frame;
/// a time a real fraction of a frame away does not. 25 fps is not a project rate, but nothing in the rule may depend on that.
private func checkFrameGridMath() {
    for fps in [24, 25, 30, 60] {
        let grid = FrameGrid(fps: fps)
        var off: [Int] = []
        for index in 0..<200_000 where grid.frame(containing: grid.time(ofFrame: index)) != index
            || grid.firstFrame(atOrAfter: grid.time(ofFrame: index)) != index {
            off.append(index)
        }
        check(off.isEmpty, "FrameGrid @\(fps): exact frame times not on their own frame: \(off.prefix(5))")
        let start = grid.time(ofFrame: fps / 2)
        let sums = (0..<(10 * fps)).filter { grid.frame(containing: start + Double($0) / Double(fps)) != fps / 2 + $0 }
        check(sums.isEmpty, "FrameGrid @\(fps): start + k / fps not on frame start + k for k = \(sums.prefix(5))")
        let near = grid.time(ofFrame: 100)
        let thousandth = 0.001 / Double(fps)
        check(grid.frame(containing: near - thousandth) == 99 && grid.firstFrame(atOrAfter: near + thousandth) == 101,
              "FrameGrid @\(fps): a thousandth of a frame off the grid is not on it")
    }
    // The old rule, for the record: a plain floor puts 123 / 30 s on frame 122.
    check((Double(123) / 30 * 30).rounded(.down) == 122 && FrameGrid(fps: 30).frame(containing: Double(123) / 30) == 123,
          "FrameGrid: 123 / 30 s is frame 123 (a plain floor says 122)")
}

/// Main track: seven pieces of black with hard cuts and two crossfades (lengths not whole frames), so the frame
/// timestamps after them carry the microsecond error production has. Overlays: see the file header.
private func movingScene(_ rate: ProjectFrameRate, source: URL, canvas: CGSize) -> TimelineState {
    var state = TimelineState()
    state.frameRate = rate
    let lengths = [2.13, 1.97, 2.71, 3.33, 2.07, 4.19, 3.11]
    let crossfades = [0, 0.5, 0, 0.73, 0.4, 0, 0]
    var cursor = 0.0
    for (index, length) in lengths.enumerated() {
        let fade = crossfades[index]
        state.mainClips.append(EditClip(
            sourceURL: source, sourceStart: Double(index) * 0.37, sourceDuration: length, timelineStart: cursor,
            transitionAfter: fade > 0 ? .crossFade : .none, transitionDuration: fade > 0 ? fade : 0.5,
            info: info(canvas, seconds: 30)
        ))
        cursor += length - fade
    }
    let wipe = TextAnimation(entrance: .wipe, exit: .wipe, entranceDuration: 0.75, exitDuration: 0.75,
                             emphasis: .none, intensity: 0.6)
    state.textOverlays = [
        plateTitle(start: 0.5, duration: 3, centerY: 0.16, animation: wipe, canvas: canvas),
        plateTitle(start: 9.5, duration: 2.5, centerY: 0.84, animation: wipe, canvas: canvas)
    ]
    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 3.36, duration: 2.6, color: .white,
                                centerX: 0.35, centerY: 0.5, width: 0.6, height: 0.1)
    shape.isFilled = true
    shape.animation = ShapeAnimation(entrance: .wipe, exit: .wipe, entranceDuration: 0.75, exitDuration: 0.75)
    // A still square whose start and end sit on the grid at 30 and 60 fps, after the cuts: its first frame must be there.
    var square = ShapeAnnotation(kind: .square, timelineStart: 7.2, duration: 1, color: .white, centerX: 0.9,
                                 centerY: 0.5, width: 0.08)
    square.isFilled = true
    state.shapes = [shape, square]
    return state
}

/// White words on a white plate in a box that hugs them: the wipe sweeps the box, so the lit width is one clean edge
/// that moves on every frame of the wipe up to the last (a still drawn before the wipe has finished shows a cut edge).
private func plateTitle(
    start: Double, duration: Double, centerY: Double, animation: TextAnimation, canvas: CGSize
) -> TextOverlay {
    var style = TextStyle.default
    style.fontSize = 220
    style.shadow = nil
    style.fill = .solid(.white)
    style.background = TextBackground(color: .white, cornerRadius: 0, paddingX: 28, paddingY: 14)
    var title = TextOverlay(text: "MOVING", timelineStart: start, duration: duration, centerX: 0.5, centerY: centerY,
                            boxWidth: 0.9, style: style, animation: animation)
    let wide = plateWidth(title, canvas: canvas)
    let padding = 28 * canvas.height / TextStyle.referenceHeight
    title.boxWidth = (Double(wide) - 2 * padding + 2) / canvas.width
    check(wide > 200 && plateWidth(title, canvas: canvas) == wide,
          "moving overlays: the snug box keeps the words on one line (plate \(wide) px)")
    return title
}

/// How wide the plate is, in pixels (lit columns across the middle of the settled title).
private func plateWidth(_ title: TextOverlay, canvas: CGSize) -> Int {
    guard let rendered = TextRenderer.render(title, canvas: canvas), let mask = alphaMask(rendered.image) else { return 0 }
    let row = mask.height / 2
    return (0..<mask.width).filter { mask.alpha[row * mask.width + $0] > 128 }.count
}

private func checkStrip(_ strip: MovingStrip, in url: URL, state: TimelineState, rate: ProjectFrameRate, canvas: CGSize) {
    let fps = rate.fps
    let frames = stripColumns(url, strip: strip, name: "moving-\(fps)-\(strip.y)", width: Int(canvas.width))
    guard frames.count >= Int(state.duration * Double(fps)) - 2 else {
        check(false, "moving \(strip.name) @\(fps)fps: only \(frames.count) frames decoded")
        return
    }
    // Most of the strip is black most of the time (the median); the overlays are white (the brightest value).
    let values = frames.flatMap(\.columns).sorted()
    let dark = Double(values[values.count / 2])
    let lit = Double(values[values.count - 1])
    guard lit - dark > 60 else {
        check(false, "moving \(strip.name) @\(fps)fps: nothing lit in the strip (\(dark) → \(lit))")
        return
    }
    let threshold = (dark + lit) / 2
    var measured: [Int: Int] = [:]
    for frame in frames {
        measured[Int((frame.time * Double(fps)).rounded())] = frame.columns.filter { Double($0) > threshold }.count
    }
    var expected: [Int: Int] = [:]
    for index in measured.keys {
        expected[index] = expectedLitColumns(strip, state: state, frame: index, rate: rate, canvas: canvas)
    }
    var wrong: [String] = []
    var stuck: [String] = []
    for index in measured.keys.sorted() {
        guard let got = measured[index], let want = expected[index] else { continue }
        if abs(got - want) > 2 {
            wrong.append(describe(index, got: got, expected: expected, fps: fps))
        }
        // While it moves (the expected count changes by more than the codec's blur), two frames in a row never match.
        if let before = expected[index - 1], abs(want - before) >= 4, let previous = measured[index - 1],
           abs(got - previous) < 2 {
            stuck.append(String(format: "%d (%.4fs)", index, Double(index) / Double(fps)))
        }
    }
    check(wrong.isEmpty, "moving \(strip.name) @\(fps)fps: \(wrong.count) frames not the frame for their own time: "
          + wrong.prefix(8).joined(separator: "; "))
    check(stuck.isEmpty, "moving \(strip.name) @\(fps)fps: frame repeats the one before while it moves: "
          + stuck.prefix(8).joined(separator: ", "))
}

/// Which frame the measured count looks like (the neighbour it matches), for the failure message.
private func describe(_ index: Int, got: Int, expected: [Int: Int], fps: Int) -> String {
    let want = expected[index] ?? -1
    var looksLike = ""
    for offset in [-1, 1, -2, 2] {
        if let other = expected[index + offset], abs(other - got) <= 2, abs(other - want) > 2 {
            looksLike = offset < 0 ? " = frame \(index + offset) (late)" : " = frame \(index + offset) (early)"
            break
        }
    }
    return String(format: "%d (%.4fs) lit %d want %d%@", index, Double(index) / Double(fps), got, want, looksLike)
}

/// Lit columns in the strip on frame `index`, from the preview's renderers at exactly `index / fps`. An overlay is on
/// frame `index` when its start ≤ that time < its end (the preview's `contains(time:)`), counted in whole frames so a
/// start on the grid is on the grid.
private func expectedLitColumns(
    _ strip: MovingStrip, state: TimelineState, frame index: Int, rate: ProjectFrameRate, canvas: CGSize
) -> Int {
    let fps = Double(rate.fps)
    let time = Double(index) / fps
    func shows(_ start: Double, _ end: Double) -> Bool {
        index >= Int((start * fps - 1e-6).rounded(.up)) && index < Int((end * fps - 1e-6).rounded(.up))
    }
    var coverage = [Double](repeating: 0, count: Int(canvas.width))
    func add(_ image: CGImage, origin: CGPoint) {
        guard let mask = alphaMask(image) else { return }
        for x in 0..<mask.width {
            let column = Int(origin.x) + x
            guard column >= 0, column < coverage.count else { continue }
            var sum = 0.0
            for row in strip.y..<(strip.y + strip.height) {
                let y = row - Int(origin.y)
                if y >= 0, y < mask.height { sum += Double(mask.alpha[y * mask.width + x]) / 255 }
            }
            coverage[column] = max(coverage[column], sum / Double(strip.height))
        }
    }
    for shape in state.shapes where shows(shape.timelineStart, shape.timelineEnd) {
        if let image = ShapePNGRenderer.image(shape, canvas: canvas, state: ShapeAnimator.state(for: shape, at: time)) {
            add(image, origin: .zero)
        }
    }
    for text in state.textOverlays where shows(text.timelineStart, text.timelineEnd) {
        let animation = TextAnimator.state(for: text, at: time, canvas: canvas, frameRate: rate)
        if let rendered = TextRenderer.render(text, canvas: canvas, state: animation) {
            add(rendered.image, origin: rendered.origin)
        }
    }
    return coverage.filter { $0 > 0.5 }.count
}

/// Every frame of the film: its time and the strip squeezed to one row (each column = the strip's average there).
private func stripColumns(
    _ url: URL, strip: MovingStrip, name: String, width: Int
) -> [(time: Double, columns: [UInt8])] {
    let raw = root.appendingPathComponent("\(name).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
        "-vf", "crop=\(width):\(strip.height):0:\(strip.y),scale=\(width):1:flags=area,format=gray",
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw) else {
        check(false, "\(name): could not decode the strip: \(out.suffix(300))")
        return []
    }
    let (probeCode, log) = run(ffmpegPath, [
        "-hide_banner", "-i", url.path, "-vf", "showinfo", "-fps_mode", "passthrough", "-f", "null", "-"
    ])
    let stamps = log.split(separator: "\n").compactMap { line -> Double? in
        guard line.contains("Parsed_showinfo"), let range = line.range(of: "pts_time:") else { return nil }
        return Double(line[range.upperBound...].prefix { $0 == "." || $0.isNumber })
    }
    let bytes = [UInt8](data)
    guard probeCode == 0, stamps.count * width == bytes.count else {
        check(false, "\(name): \(stamps.count) timestamps for \(bytes.count / max(1, width)) frames")
        return []
    }
    return stamps.enumerated().map { index, time in
        (time: time, columns: Array(bytes[(index * width)..<((index + 1) * width)]))
    }
}

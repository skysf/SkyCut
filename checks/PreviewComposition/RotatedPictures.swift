import AVFoundation
import CoreGraphics
import Foundation

// Turned and moving pictures in the real preview composition (the frames look composes come from this builder):
// - rotation keyframes are cut into slices of at most 6° (moved here from main.swift, which may only shrink);
// - the bare edges and corners of real frames are where `PictureCoverage` / `ClipCoverage` say they are — the geometry behind
//   get_timeline's fills_frame and look's uncovered, held against what the compositor actually draws (2026-11-17, P5 walkthrough
//   to-do 3: rotation 5 at scale 1.1 reported fills_frame true while look showed a bare corner;
//   docs/bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md).
// Built by scripts/check-preview-composition.sh.

func checkRotatedPictures(white1: URL) async throws {
    await checkRotationSlices(white1: white1)
    try await checkCoverageMatchesFrames()
}

// C. 旋转关键帧要按 ≤6°/片加密（矩阵插值走弦，不加密就是缩水变形）。
private func checkRotationSlices(white1: URL) async {
    var state = TimelineState()
    let info = MediaInfo(
        duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
    var clip = EditClip(sourceURL: white1, sourceDuration: 4, timelineStart: 0, info: info)
    var animation = ClipAnimation()
    animation.rotation.set(0, atSourceTime: 0, tolerance: kfTol)
    animation.rotation.set(90, atSourceTime: 4, tolerance: kfTol)
    clip.animation = animation
    state.mainClips = [clip]
    if let built = await VideoEditCompositionBuilder.build(from: state) {
        let count = built.videoComposition?.instructions.count ?? 0
        check(count >= 15, "旋转 90° 动画至少切成 15 片（≤6°/片），实测 \(count)")
    } else {
        check(false, "旋转动画场景合成失败")
    }
}

/// A white 640×360 clip on its own 16:9 frame, turned, flipped and moved: the dark runs along the frame's edges match the predicted
/// gaps within 2 px (the compositor antialiases), and a clip at its fill_scale leaves no dark edge pixel.
private func checkCoverageMatchesFrames() async throws {
    let size = CGSize(width: 640, height: 360)
    let white = try await makeSolidVideo(white: 1, seconds: 4, name: "coverage-white.mp4", size: size)
    let info = MediaInfo(
        duration: 4, displaySize: size, frameRate: 10, videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
    func clip(_ edit: (inout EditClip) -> Void) -> TimelineState {
        var clip = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: info)
        edit(&clip)
        var state = TimelineState()
        state.mainClips = [clip]
        return state
    }
    let turned = clip { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.1, height: 1.1); $0.rotationDegrees = 5 }
    let flipped = clip {
        $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.1, height: 1.1)
        $0.rotationDegrees = 5
        $0.flippedHorizontally = true
        $0.flippedVertically = true
    }
    let drift = clip {
        var animation = ClipAnimation()
        animation.centerX = KeyframeTrack(keys: [Keyframe(time: 0, value: 0.5), Keyframe(time: 4, value: 0.6)])
        $0.animation = animation
    }
    let turning = clip {
        $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.1, height: 1.1)
        var animation = ClipAnimation()
        animation.rotation = KeyframeTrack(keys: [Keyframe(time: 0, value: 0), Keyframe(time: 4, value: -10)])
        $0.animation = animation
    }
    for (label, state, time) in [("5° at 1.1", turned, 1.0), ("5° at 1.1 flipped", flipped, 1.0), ("drift x 0.5 → 0.6", drift, 3.0),
                                 ("turning to −10°", turning, 3.0)] {
        await compare(state, at: time, label)
    }
    // At fill_scale the turned clip covers the real frame (a corner pixel may be only just half covered: at most 2 dark edge pixels);
    // 0.02 less and the corners show.
    guard let fillScale = ClipCoverage.fill(turned.mainClips[0], canvas: size).fillScale else {
        return check(false, "the turned clip reports a fill_scale")
    }
    func scaled(_ scale: Double) -> TimelineState {
        clip { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: scale, height: scale); $0.rotationDegrees = 5 }
    }
    check(ClipCoverage.fill(scaled(fillScale).mainClips[0], canvas: size).fillsFrame, "at fill_scale \(fillScale) the turned clip fills")
    let filled = await coverageFrame(scaled(fillScale), at: 1)
    let short = await coverageFrame(scaled(fillScale - 0.02), at: 1)
    check((filled?.darkEdgePixels ?? 99) <= 2, "at fill_scale the real frame's edges are covered (\(filled?.darkEdgePixels ?? -1) dark)")
    check((short?.darkEdgePixels ?? 0) > 10, "0.02 under fill_scale the real frame's corners show (\(short?.darkEdgePixels ?? -1) dark)")
}

/// Predicted gaps at `time` against the real frame: every predicted edge's depth within 2 px, every corner's runs within 2 px plus what
/// the compositor's antialiasing (up to about 0.6 px across the box edge) moves them along a shallow edge, nothing dark elsewhere.
private func compare(_ state: TimelineState, at time: Double, _ label: String) async {
    let canvas = VideoEditCompositionBuilder.renderSize(for: state)
    let gaps = PictureCoverage.gaps(ClipCoverage.coveringPictures(in: state, at: time, canvas: canvas), canvas: canvas)
    guard let frame = await coverageFrame(state, at: time) else { return check(false, "\(label): the composition renders") }
    check(!gaps.isEmpty, "\(label): the geometry predicts a bare edge or corner")
    for edge in PictureCoverage.Edge.allCases {
        let measured = frame.deepest(edge)
        let predicted = gaps.edges[edge]
        check(predicted.map { abs($0 - measured) <= 2 } ?? (measured <= 1),
              "\(label): \(edge) edge — predicted \(predicted.map(String.init) ?? "none"), the frame shows \(measured) px")
    }
    let corners: [(PictureCoverage.Corner, PictureCoverage.Edge, Bool, PictureCoverage.Edge, Bool)] = [
        (.topLeft, .top, false, .left, false), (.topRight, .top, true, .right, false),
        (.bottomLeft, .bottom, false, .left, true), (.bottomRight, .bottom, true, .right, true)
    ]
    for (corner, across, acrossFromEnd, down, downFromEnd) in corners where gaps.edges[across] == nil && gaps.edges[down] == nil {
        let measured = PictureCoverage.Extent(width: frame.run(across, fromEnd: acrossFromEnd), height: frame.run(down, fromEnd: downFromEnd))
        let predicted = gaps.corners[corner] ?? PictureCoverage.Extent(width: 0, height: 0)
        let slope = Double(max(1, predicted.width)) / Double(max(1, predicted.height))
        let slackWidth = 2 + 0.6 * slope, slackHeight = 2 + 0.6 / slope
        check(abs(Double(measured.width - predicted.width)) <= slackWidth && abs(Double(measured.height - predicted.height)) <= slackHeight,
              "\(label): \(corner) — predicted \(predicted), the frame shows \(measured)")
    }
}

/// One real frame of the composition, read as dark (below `darkBelow`: half brightness by default) or not. Also read by
/// EntranceCover.swift, where a fading picture is dark below half its own brightness.
struct CoverageFrame {
    let width: Int
    let height: Int
    let dark: [Bool]

    func isDark(_ x: Int, _ y: Int) -> Bool { dark[y * width + x] }

    /// Dark pixels from the edge pixel at `index` straight in.
    func depth(_ edge: PictureCoverage.Edge, at index: Int) -> Int {
        var count = 0
        switch edge {
        case .top: while count < height, isDark(index, count) { count += 1 }
        case .bottom: while count < height, isDark(index, height - 1 - count) { count += 1 }
        case .left: while count < width, isDark(count, index) { count += 1 }
        case .right: while count < width, isDark(width - 1 - count, index) { count += 1 }
        }
        return count
    }

    private func length(_ edge: PictureCoverage.Edge) -> Int { edge == .top || edge == .bottom ? width : height }

    /// The deepest dark run in from any pixel of the edge, corners excluded unless the whole edge is dark.
    func deepest(_ edge: PictureCoverage.Edge) -> Int {
        let depths = (0..<length(edge)).map { depth(edge, at: $0) }
        guard !depths.allSatisfy({ $0 > 0 }) else { return depths.max() ?? 0 }
        // Leave out the runs that start at a corner (they are the corner's).
        let leading = depths.prefix { $0 > 0 }.count, trailing = depths.reversed().prefix { $0 > 0 }.count
        return depths.dropFirst(leading).dropLast(trailing).max() ?? 0
    }

    /// Dark pixels along the edge from one of its ends.
    func run(_ edge: PictureCoverage.Edge, fromEnd: Bool) -> Int {
        let indices = Array(0..<length(edge))
        return (fromEnd ? Array(indices.reversed()) : indices).prefix { depth(edge, at: $0) > 0 }.count
    }

    var darkEdgePixels: Int {
        PictureCoverage.Edge.allCases.reduce(0) { total, edge in total + (0..<length(edge)).filter { depth(edge, at: $0) > 0 }.count }
    }
}

func coverageFrame(_ state: TimelineState, at seconds: Double, darkBelow level: Int = 128) async -> CoverageFrame? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else { return nil }
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Bitmap memory starts with the image's top row.
    let dark = (0..<(width * height)).map { index -> Bool in
        let red = Int(pixels[index * 4]), green = Int(pixels[index * 4 + 1]), blue = Int(pixels[index * 4 + 2])
        return red + green + blue < 3 * level
    }
    return CoverageFrame(width: width, height: height, dark: dark)
}

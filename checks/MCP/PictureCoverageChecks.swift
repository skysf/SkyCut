import CoreGraphics
import Foundation
import SrtFlowMCPKit

// Does a picture cover the canvas (`PictureCoverage`): every answer is held against a reference that does not share its maths — a
// bitmap where a pixel is covered when its centre, taken back through the inverse of CoreGraphics's own transform for the picture
// (move to the box's centre, turn with CGAffineTransform's rotation, as the preview's `placedTransform` does), lands in the box; bare
// runs and depths are then counted pixel by pixel. (CoreGraphics's aliased fill is no reference: it also fills pixels a box edge only
// clips, 6 px off along a 5° edge.) The real preview's frames are held against the same geometry in
// scripts/check-preview-composition.sh (Coverage.swift).
// P5 walkthrough to-do 3 (2026-11-17): rotation 5 at scale 1.1 reported fills_frame true while look showed a bare corner.
// Case: docs/bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md. Clip-level and look checks: ClipCoverageChecks.swift.

func runPictureCoverageChecks() {
    checkRotationSweepAgainstRaster()
    checkFillFactorIsTheSmallestGrowth()
    checkGapsBetweenPictures()
    checkHalfWipe()
    runClipCoverageChecks()
}

/// The reference bitmap: 255 where some picture is drawn, 0 where the canvas is bare. Row 0 is the top.
struct CoverageRaster {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(_ pictures: [PictureCoverage.Picture], canvas: CGSize) {
        width = Int(canvas.width)
        height = Int(canvas.height)
        // Each picture: its drawn rectangle around the origin, and the canvas-to-picture transform (inverse of "turn, then move").
        let shapes = pictures.map { picture -> (CGRect, CGAffineTransform) in
            let frame = picture.frame
            let from = picture.revealed.lowerBound, to = picture.revealed.upperBound
            let drawn = CGRect(x: frame.width * (from - 0.5), y: -frame.height / 2, width: frame.width * (to - from), height: frame.height)
            let placed = CGAffineTransform(rotationAngle: picture.rotationDegrees * .pi / 180)
                .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
            return (drawn, placed.inverted())
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let centre = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if shapes.contains(where: { $0.0.contains(centre.applying($0.1)) }) { pixels[y * width + x] = 255 }
            }
        }
        self.pixels = pixels
    }

    func bare(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] < 128 }

    var allCovered: Bool { !pixels.contains { $0 < 128 } }

    /// Bare pixels counted straight in from an edge pixel.
    func depth(fromEdge edge: PictureCoverage.Edge, at index: Int) -> Int {
        var count = 0
        switch edge {
        case .top: while count < height, bare(index, count) { count += 1 }
        case .bottom: while count < height, bare(index, height - 1 - count) { count += 1 }
        case .left: while count < width, bare(count, index) { count += 1 }
        case .right: while count < width, bare(width - 1 - count, index) { count += 1 }
        }
        return count
    }

    /// The gaps as the bitmap shows them, read with the rule `PictureCoverage.Gaps` documents (whole bare edges and gaps between the
    /// corners of an edge report their deepest point; corners report how far they run along each edge when neither edge is bare all
    /// along).
    func gaps() -> PictureCoverage.Gaps {
        func line(_ edge: PictureCoverage.Edge) -> [Int] {
            let count = edge == .top || edge == .bottom ? width : height
            return (0..<count).map { depth(fromEdge: edge, at: $0) }
        }
        let lines = Dictionary(uniqueKeysWithValues: PictureCoverage.Edge.allCases.map { ($0, line($0)) })
        let whole = Set(PictureCoverage.Edge.allCases.filter { lines[$0]!.allSatisfy { $0 > 0 } })
        var gaps = PictureCoverage.Gaps()
        for (edge, depths) in lines {
            if whole.contains(edge) { gaps.edges[edge] = depths.max(); continue }
            var start = 0
            while start < depths.count {
                guard depths[start] > 0 else { start += 1; continue }
                var end = start
                while end + 1 < depths.count, depths[end + 1] > 0 { end += 1 }
                if start > 0, end < depths.count - 1 { gaps.edges[edge] = max(gaps.edges[edge] ?? 0, depths[start...end].max()!) }
                start = end + 1
            }
        }
        func run(_ edge: PictureCoverage.Edge, fromEnd: Bool) -> Int {
            let depths = lines[edge]!
            return (fromEnd ? Array(depths.reversed()) : depths).prefix { $0 > 0 }.count
        }
        let corners: [(PictureCoverage.Corner, PictureCoverage.Edge, Bool, PictureCoverage.Edge, Bool)] = [
            (.topLeft, .top, false, .left, false), (.topRight, .top, true, .right, false),
            (.bottomLeft, .bottom, false, .left, true), (.bottomRight, .bottom, true, .right, true)
        ]
        for (corner, across, acrossEnd, down, downEnd) in corners where !whole.contains(across) && !whole.contains(down) {
            let extent = PictureCoverage.Extent(width: run(across, fromEnd: acrossEnd), height: run(down, fromEnd: downEnd))
            if extent.width > 0, extent.height > 0 { gaps.corners[corner] = extent }
        }
        return gaps
    }
}

/// Same edges and corners, every number within `tolerance` pixels; an edge or corner only one side has must be within `tolerance`
/// of nothing (a pixel centre right on a box edge may land either way, in the bitmap's fixed-point rasteriser more than in doubles).
func gapsAgree(_ a: PictureCoverage.Gaps, _ b: PictureCoverage.Gaps, tolerance: Int = 1) -> Bool {
    for edge in Set(a.edges.keys).union(b.edges.keys) where abs((a.edges[edge] ?? 0) - (b.edges[edge] ?? 0)) > tolerance {
        return false
    }
    let none = PictureCoverage.Extent(width: 0, height: 0)
    for corner in Set(a.corners.keys).union(b.corners.keys) {
        let one = a.corners[corner] ?? none, other = b.corners[corner] ?? none
        if abs(one.width - other.width) > tolerance || abs(one.height - other.height) > tolerance { return false }
    }
    return true
}

/// A box of `aspect` (width / height) that fits the canvas at scale 1, grown by `scale`, centred at (cx, cy) (fractions of the canvas).
func coverageBox(canvas: CGSize, aspect: Double, scale: Double, cx: Double = 0.5, cy: Double = 0.5) -> CGRect {
    let fit = min(canvas.width / aspect, canvas.height)
    let size = CGSize(width: fit * aspect * scale, height: fit * scale)
    return CGRect(x: cx * canvas.width - size.width / 2, y: cy * canvas.height - size.height / 2, width: size.width, height: size.height)
}

/// Rotations −30…30°, sizes, off-centre boxes, wide and tall canvases and pictures: covers / does not cover and the bare edges and
/// corners agree with the bitmap. Covering is not compared right at its threshold (within 1 %): a pixel centre exactly on the box
/// edge may go either way.
private func checkRotationSweepAgainstRaster() {
    var cases = 0, wrongCovers = 0, wrongGaps = 0
    var firstWrong: String?
    for canvas in [CGSize(width: 192, height: 108), CGSize(width: 108, height: 192)] {
        for aspect in [16.0 / 9, 9.0 / 16] {
            for degrees in stride(from: -30.0, through: 30.0, by: 5.0) {
                for scale in [0.9, 1.0, 1.1, 1.2, 1.3, 1.5, 2.2] {
                    for (cx, cy) in [(0.5, 0.5), (0.46, 0.55), (0.6, 0.42)] {
                        let picture = PictureCoverage.Picture(
                            frame: coverageBox(canvas: canvas, aspect: aspect, scale: scale, cx: cx, cy: cy), rotationDegrees: degrees
                        )
                        let factor = PictureCoverage.fillFactor(picture, canvas: canvas)
                        let raster = CoverageRaster([picture], canvas: canvas)
                        cases += 1
                        if abs(factor - 1) > 0.01, PictureCoverage.covers(picture, canvas: canvas) != raster.allCovered {
                            wrongCovers += 1
                        }
                        if !gapsAgree(PictureCoverage.gaps([picture], canvas: canvas), raster.gaps()) {
                            wrongGaps += 1
                            firstWrong = firstWrong ?? "\(canvas) aspect \(aspect) \(degrees)° ×\(scale) at (\(cx), \(cy))"
                        }
                    }
                }
            }
        }
    }
    check(cases == 1092, "the sweep ran every case (\(cases))")
    checkEqual(wrongCovers, 0, "covers agrees with the bitmap over the rotation sweep")
    check(wrongGaps == 0, "gaps agree with the bitmap over the rotation sweep (\(wrongGaps) wrong, first: \(firstWrong ?? "-"))")
}

/// fillFactor is the smallest growth about the box's centre that covers: just above it covers, 1 % below it does not.
private func checkFillFactorIsTheSmallestGrowth() {
    let canvas = CGSize(width: 192, height: 108)
    var wrong = 0
    for degrees in [-25.0, -5, 0, 3, 5, 12, 45] {
        for (cx, cy) in [(0.5, 0.5), (0.4, 0.58)] {
            let frame = coverageBox(canvas: canvas, aspect: 16.0 / 9, scale: 1, cx: cx, cy: cy)
            let factor = PictureCoverage.fillFactor(PictureCoverage.Picture(frame: frame, rotationDegrees: degrees), canvas: canvas)
            func grown(_ by: Double) -> PictureCoverage.Picture {
                PictureCoverage.Picture(frame: frame.insetBy(dx: -frame.width * (by - 1) / 2, dy: -frame.height * (by - 1) / 2),
                                        rotationDegrees: degrees)
            }
            if !CoverageRaster([grown(factor * 1.0001)], canvas: canvas).allCovered { wrong += 1 }
            if CoverageRaster([grown(factor * 0.99)], canvas: canvas).allCovered { wrong += 1 }
        }
    }
    checkEqual(wrong, 0, "fillFactor is the smallest growth that covers (bitmap above and below it)")
    // The walkthrough on a full 1920×1080 canvas: 16:9 at scale 1.1 turned 5° needs about 1.15.
    let canvas1080 = CGSize(width: 1920, height: 1080)
    let walkthrough = PictureCoverage.Picture(frame: coverageBox(canvas: canvas1080, aspect: 16.0 / 9, scale: 1.1), rotationDegrees: 5)
    let needed = 1.1 * PictureCoverage.fillFactor(walkthrough, canvas: canvas1080)
    check(abs(needed - 1.1501) < 0.0005, "5° at 1.1 needs scale ≈ 1.1501 (got \(needed))")
    check(!PictureCoverage.covers(walkthrough, canvas: canvas1080), "5° at 1.1 does not cover a 16:9 frame")
    let raster = CoverageRaster([walkthrough], canvas: canvas1080)
    let gaps = PictureCoverage.gaps([walkthrough], canvas: canvas1080)
    check(gapsAgree(gaps, raster.gaps()), "5° at 1.1: gaps agree with the bitmap (\(gaps) vs \(raster.gaps()))")
    // Clockwise: the top edge dips on the right, so the top-right and bottom-left corners are bare (the walkthrough saw top right).
    checkEqual(Set(gaps.corners.keys), [.topRight, .bottomLeft], "a clockwise turn bares the top-right and bottom-left corners")
    check(gaps.edges.isEmpty, "5° at 1.1: no whole edge is bare")
    checkEqual(PictureCoverage.gaps([walkthrough.with(rotation: -5)], canvas: canvas1080).corners.keys.sorted { $0.rawValue < $1.rawValue },
               [.bottomRight, .topLeft], "an anticlockwise turn bares the other two corners")
}

/// Two pictures side by side with a gap between them: the gap is reported on the top and bottom edges; a third picture over the gap
/// covers it.
private func checkGapsBetweenPictures() {
    let canvas = CGSize(width: 192, height: 108)
    let left = PictureCoverage.Picture(frame: CGRect(x: -1, y: -1, width: 90, height: 110))
    let right = PictureCoverage.Picture(frame: CGRect(x: 100, y: -1, width: 93, height: 110))
    let gaps = PictureCoverage.gaps([left, right], canvas: canvas)
    check(gapsAgree(gaps, CoverageRaster([left, right], canvas: canvas).gaps()), "a gap between two pictures agrees with the bitmap")
    checkEqual(Set(gaps.edges.keys), [.top, .bottom], "a gap between two pictures shows on the top and bottom edges")
    checkEqual(gaps.edges[.top], 108, "the gap between two pictures runs from top to bottom")
    let middle = PictureCoverage.Picture(frame: CGRect(x: 80, y: -1, width: 30, height: 110), rotationDegrees: 2)
    check(PictureCoverage.gaps([left, right, middle], canvas: canvas).isEmpty, "a picture over the gap covers it")
    check(PictureCoverage.gaps([], canvas: canvas) == PictureCoverage.Gaps(edges: [.top: 108, .bottom: 108, .left: 192, .right: 192]),
          "no picture: every edge bare all the way across")
}

/// A wipe half-way in draws the left half of the box (the right half when the clip is flipped): the bare half is reported.
private func checkHalfWipe() {
    let canvas = CGSize(width: 192, height: 108)
    let frame = CGRect(x: 0, y: 0, width: 192, height: 108)
    for revealed in [0.0...0.5, 0.5...1.0] {
        let picture = PictureCoverage.Picture(frame: frame, revealed: revealed)
        let gaps = PictureCoverage.gaps([picture], canvas: canvas)
        check(gapsAgree(gaps, CoverageRaster([picture], canvas: canvas).gaps()), "a half wipe agrees with the bitmap (\(revealed))")
        checkEqual(gaps.edges[revealed.lowerBound == 0 ? .right : .left], 96, "a half wipe bares half the width (\(revealed))")
        check(PictureCoverage.fillFactor(picture, canvas: canvas).isInfinite, "no growth about the centre fills a half wipe")
    }
}

extension PictureCoverage.Picture {
    func with(rotation degrees: Double) -> PictureCoverage.Picture {
        var copy = self
        copy.rotationDegrees = degrees
        return copy
    }
}

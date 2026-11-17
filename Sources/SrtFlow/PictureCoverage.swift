import CoreGraphics
import Foundation

// MARK: - Does a picture cover the canvas? (pure geometry)
//
// What: one picture on the canvas is its box (`ClipPlacement.frame(in:)`, canvas pixels, top-left origin) turned clockwise by its
// rotation about the box's own centre — the order both pipelines draw it in (preview: `placedTransform` in
// VideoEditCompositionBuilder scales the picture into the box, rotates about the box's centre, moves it into place; export:
// `transformSteps` scales, rotates, overlays at the centre). Flips mirror the picture inside its box and a crop only changes the box's
// shape (the default fit follows the cropped picture), so neither changes what the box covers. A wipe part-way shows only part of the
// box (`revealed`). From that: how much a picture would have to grow about its centre to cover the whole canvas (`fillFactor`, ≤ 1:
// it covers), and which edges and corners of the canvas no picture covers (`gaps`), in canvas pixels.
// Not: where a clip's box is at a moment (`ClipCoverage`), what shows where nothing covers (black on V1, V1 under V2), opacity.
// One function for get_timeline's fills_frame and look's uncovered: docs/architecture/preview-free-transform.md
// ("Does the picture cover the frame").

enum PictureCoverage {
    /// One picture on the canvas.
    struct Picture: Equatable {
        /// Its box in canvas pixels (top-left origin), before rotation.
        var frame: CGRect
        /// Clockwise degrees about the box's centre.
        var rotationDegrees: Double = 0
        /// The part of the box that is drawn, as fractions of its width from its left edge (a wipe half-way in: 0...0.5).
        var revealed: ClosedRange<Double> = 0...1
    }

    /// The canvas is sampled at pixel centres: a picture whose edge is within half a pixel of the canvas edge covers it. Same tolerance
    /// as the axis-aligned check this replaces (`frame.minX <= 0.5 && … frame.maxY >= height - 0.5`).
    static let pixelCentre = 0.5

    /// How much the picture must grow about its centre to cover the whole canvas: ≤ 1 covers it, 1.05 needs 5 % more,
    /// `.infinity` when no growth can (nothing is drawn, or a wipe has not reached the centre yet). `inset`: how far in from the canvas
    /// corners the corners that must be covered are — the corner pixels' centres (whether it covers), or 0 for the canvas's own corners
    /// (fill_scale: the compositor's edges can sit a fraction of a pixel off, and a scale meant to cover should cover whole pixels).
    static func fillFactor(_ picture: Picture, canvas: CGSize, inset: Double = pixelCentre) -> Double {
        guard canvas.width > 0, canvas.height > 0 else { return 0 }
        let box = LocalBox(picture)
        guard box.draws else { return .infinity }
        let insetX = min(inset, canvas.width / 2), insetY = min(inset, canvas.height / 2)
        let corners = [
            CGPoint(x: insetX, y: insetY), CGPoint(x: canvas.width - insetX, y: insetY),
            CGPoint(x: canvas.width - insetX, y: canvas.height - insetY), CGPoint(x: insetX, y: canvas.height - insetY)
        ]
        // The canvas is convex: covering its four corner pixels covers all of it.
        return corners.reduce(0) { factor, corner in
            let point = box.local(corner)
            return max(factor, growth(point.x, box.u), growth(point.y, box.v))
        }
    }

    /// Covers the whole canvas.
    static func covers(_ picture: Picture, canvas: CGSize) -> Bool {
        fillFactor(picture, canvas: canvas) <= 1 + 1e-9
    }

    /// How much a range around 0 must grow to reach `value`.
    private static func growth(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        if value > 0 { return range.upperBound > 0 ? value / range.upperBound : .infinity }
        if value < 0 { return range.lowerBound < 0 ? value / range.lowerBound : .infinity }
        return 0
    }

    // MARK: What no picture covers

    enum Edge: String, CaseIterable {
        case top, bottom, left, right
    }

    enum Corner: String, CaseIterable {
        case topLeft = "top_left", topRight = "top_right", bottomLeft = "bottom_left", bottomRight = "bottom_right"
    }

    /// Pixels along the horizontal edge and along the vertical edge.
    struct Extent: Equatable {
        var width: Int
        var height: Int
    }

    /// The bare parts of the canvas, in canvas pixels.
    struct Gaps: Equatable {
        /// An edge bare along its whole length (a strip), or bare somewhere between its corners: the deepest the bare part reaches in
        /// from that edge.
        var edges: [Edge: Int] = [:]
        /// A bare corner when neither of its edges is bare all along: how far it runs along the top / bottom edge and down the left /
        /// right edge. (A strip along a whole edge already accounts for the corners at its ends.)
        var corners: [Corner: Extent] = [:]

        var isEmpty: Bool { edges.isEmpty && corners.isEmpty }
    }

    /// What none of `pictures` covers, along the canvas's four edges. Each edge pixel's centre is tested, and from a bare one the gap's
    /// depth is measured straight into the canvas to the first picture.
    static func gaps(_ pictures: [Picture], canvas: CGSize) -> Gaps {
        let width = Int(canvas.width.rounded()), height = Int(canvas.height.rounded())
        guard width > 0, height > 0 else { return Gaps() }
        let boxes = pictures.map(LocalBox.init).filter(\.draws)
        func depth(_ x: Double, _ y: Double, inward: CGVector, extent: Int) -> Double? {
            let point = CGPoint(x: x, y: y)
            if boxes.contains(where: { $0.contains(point) }) { return nil }
            let entry = boxes.compactMap { $0.entry(from: point, along: inward) }.min() ?? .infinity
            return min(Double(extent), pixelCentre + entry)
        }
        let right = Double(width) - pixelCentre, bottom = Double(height) - pixelCentre
        // Along each edge from one corner to the other: nil = covered, else the gap's depth there.
        let samples: [Edge: [Double?]] = [
            .top: (0..<width).map { depth(Double($0) + pixelCentre, pixelCentre, inward: CGVector(dx: 0, dy: 1), extent: height) },
            .bottom: (0..<width).map { depth(Double($0) + pixelCentre, bottom, inward: CGVector(dx: 0, dy: -1), extent: height) },
            .left: (0..<height).map { depth(pixelCentre, Double($0) + pixelCentre, inward: CGVector(dx: 1, dy: 0), extent: width) },
            .right: (0..<height).map { depth(right, Double($0) + pixelCentre, inward: CGVector(dx: -1, dy: 0), extent: width) }
        ]
        return classify(samples)
    }

    private static func classify(_ samples: [Edge: [Double?]]) -> Gaps {
        func pixels(_ depth: Double) -> Int { max(1, Int(depth.rounded())) }
        let whole = Set(Edge.allCases.filter { samples[$0]?.allSatisfy { $0 != nil } ?? false })
        var gaps = Gaps()
        for edge in Edge.allCases {
            let line = samples[edge] ?? []
            if whole.contains(edge) {
                gaps.edges[edge] = pixels(line.compactMap { $0 }.max() ?? 0)
                continue
            }
            // A run touching neither corner: a gap in the middle of the edge (between two pictures).
            var start = 0
            while start < line.count {
                guard line[start] != nil else { start += 1; continue }
                var end = start
                while end + 1 < line.count, line[end + 1] != nil { end += 1 }
                if start > 0, end < line.count - 1 {
                    let deepest = pixels(line[start...end].compactMap { $0 }.max() ?? 0)
                    gaps.edges[edge] = max(gaps.edges[edge] ?? 0, deepest)
                }
                start = end + 1
            }
        }
        // Corner pixels are shared: the first pixel of the top edge is the first of the left edge, and so on.
        func run(_ edge: Edge, fromEnd: Bool) -> Int {
            let line = samples[edge] ?? []
            return (fromEnd ? Array(line.reversed()) : line).prefix { $0 != nil }.count
        }
        let corners: [(Corner, Edge, Bool, Edge, Bool)] = [
            (.topLeft, .top, false, .left, false), (.topRight, .top, true, .right, false),
            (.bottomLeft, .bottom, false, .left, true), (.bottomRight, .bottom, true, .right, true)
        ]
        for (corner, across, acrossFromEnd, down, downFromEnd) in corners where !whole.contains(across) && !whole.contains(down) {
            let extent = Extent(width: run(across, fromEnd: acrossFromEnd), height: run(down, fromEnd: downFromEnd))
            if extent.width > 0, extent.height > 0 { gaps.corners[corner] = extent }
        }
        return gaps
    }
}

/// A picture in its own frame: the origin at the box's centre, the axes along its sides. Only the drawn part (`revealed`) counts.
private struct LocalBox {
    let centre: CGPoint
    let cosine: Double
    let sine: Double
    /// Across the box (its width), relative to the centre.
    let u: ClosedRange<Double>
    /// Down the box (its height), relative to the centre.
    let v: ClosedRange<Double>

    init(_ picture: PictureCoverage.Picture) {
        let frame = picture.frame.standardized
        centre = CGPoint(x: frame.midX, y: frame.midY)
        let radians = picture.rotationDegrees * .pi / 180
        cosine = cos(radians)
        sine = sin(radians)
        let from = min(max(picture.revealed.lowerBound, 0), 1)
        let to = min(max(picture.revealed.upperBound, from), 1)
        u = (frame.width * (from - 0.5))...(frame.width * (to - 0.5))
        v = (-frame.height / 2)...(frame.height / 2)
    }

    /// Draws anything at all.
    var draws: Bool { u.upperBound > u.lowerBound && v.upperBound > v.lowerBound }

    /// A canvas point in the box's frame: the inverse of the clockwise turn (y points down, as CGAffineTransform(rotationAngle:) does).
    func local(_ point: CGPoint) -> CGPoint {
        let dx = point.x - centre.x, dy = point.y - centre.y
        return CGPoint(x: dx * cosine + dy * sine, y: -dx * sine + dy * cosine)
    }

    func contains(_ point: CGPoint) -> Bool {
        let local = local(point)
        return u.contains(local.x) && v.contains(local.y)
    }

    /// How far from `point` along the unit vector `direction` the box begins; nil when the ray misses it.
    func entry(from point: CGPoint, along direction: CGVector) -> Double? {
        let origin = local(point)
        let step = CGPoint(x: direction.dx * cosine + direction.dy * sine, y: -direction.dx * sine + direction.dy * cosine)
        var near = 0.0, far = Double.infinity
        for (position, delta, range) in [(origin.x, step.x, u), (origin.y, step.y, v)] {
            if abs(delta) < 1e-12 {
                guard range.contains(position) else { return nil }
                continue
            }
            let a = (range.lowerBound - position) / delta, b = (range.upperBound - position) / delta
            near = max(near, min(a, b))
            far = min(far, max(a, b))
        }
        return near <= far ? near : nil
    }
}

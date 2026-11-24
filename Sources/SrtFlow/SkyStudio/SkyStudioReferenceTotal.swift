import Foundation

// MARK: - A request's reference images sharing a model's total byte limit (pure values)
// What it does: where the models publish `max_total_image_bytes` (every reference image of one request together; Seedream 5.0:
// Sky Studio's inline budget), brings a set whose images each meet their own limits within the total. It decides with real
// encoded sizes, measured again after every step, and stops as soon as the set fits. First full-size steps: the largest image
// takes its next one (a PNG written again, no pixel lost; a JPEG's next lower quality), kept only when smaller. Then sizes:
// the largest image that can still shrink comes down to the common cap (the largest c with Σ min(size, c) within what is
// left), never below SkyCut's floor. An image that cannot come down further keeps its smallest copy and the others make up for
// it; when nothing can come down any more and the set is still over, it is refused before anything is uploaded. An image never
// asked to step keeps its upload byte-identical.
// Not here: encoding (SkyStudioReferenceImageFit gives each image its steps), each image's own limits (SkyStudioReferenceFit).
// The total comes from /models; the floor is SkyCut's own rule for a reference that is still useful, not a model's limit.
// Rules: docs/architecture/reference-image-fitting.md.

/// One image of a set that shares a total, as the sharing sees it. The ImageIO side encodes real copies; checks pass synthetic
/// ones. A step or a shrink keeps a new copy only when it is smaller than what the image has.
protocol SkyStudioReferenceTotalImage {
    /// Bytes of what goes up for it now.
    var bytes: Double { get }
    /// Its next full-size step (a PNG written again at full size; a JPEG's next lower quality): false when none is left.
    mutating func step() throws -> Bool
    /// The largest size within `cap` bytes, never below SkyCut's floor: false when even the floor is over (it then keeps
    /// whichever of its copies is smallest, and comes down no further).
    mutating func shrink(to cap: Double) throws -> Bool
}

enum SkyStudioReferenceTotal {
    /// SkyCut's floor for a copy made smaller to share a total: its long side stays at least this many pixels (an image already
    /// smaller keeps its size: never upscaled) and a JPEG never goes below the lowest quality of its own fitting (0.8). Below it
    /// a reference loses most of its detail, so a set that would need less is refused instead (user, 2026-11-24: keep it).
    static let floorEdge = 512.0

    /// Brings `images` within `total`, as little as needed and the largest first; false when they cannot be brought within it.
    static func share<Image: SkyStudioReferenceTotalImage>(_ images: inout [Image], total: Double) throws -> Bool {
        func over() -> Bool { images.reduce(0) { $0 + $1.bytes } > total }
        func largest(_ among: Set<Int>) -> Int? { among.max { images[$0].bytes < images[$1].bytes } }
        // Full size first: every step is bounded (a PNG has one, a JPEG three), so this ends.
        var stepping = Set(images.indices)
        while over(), let index = largest(stepping) {
            if try !images[index].step() { stepping.remove(index) }
        }
        // Then sizes. Within one cap the caps only rise (a shrunk image leaves room), so an image shrinks at most once until
        // another is held at its floor; the bound only guards against an encoder that does not keep its word.
        var shrinking = Set(images.indices)
        for _ in 0 ..< 4 * max(1, images.count * images.count) where over() {
            let held = images.indices.filter { !shrinking.contains($0) }.reduce(0) { $0 + images[$1].bytes }
            let cap = level(shrinking.map { images[$0].bytes }, budget: total - held)
            guard let index = largest(shrinking), images[index].bytes > cap else { break }
            if try !images[index].shrink(to: cap) { shrinking.remove(index) }
        }
        return !over()
    }

    /// The largest cap with Σ min(size, cap) ≤ budget: the largest sizes come down to it and the rest stay as they are;
    /// infinity when every size fits as it is, 0 when the budget is gone.
    static func level(_ sizes: [Double], budget: Double) -> Double {
        let sorted = sizes.sorted()
        var below = 0.0
        for (index, size) in sorted.enumerated() {
            let rest = Double(sorted.count - index)
            if below + size * rest > budget { return max(0, (budget - below) / rest) }
            below += size
        }
        return .infinity
    }
}

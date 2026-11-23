import Foundation

// MARK: - A request's reference images sharing a model's total byte limit (pure values)
// What it does: where a model publishes `max_total_image_bytes` (every reference image of one request together; Seedream 5.0:
// Sky Studio's inline budget), decides what happens to each image once each one meets its own limits. The largest come down
// first, all to one common cap (the largest with Σ min(size, cap) within the total), and an image at or under the cap stays
// byte-identical. An image whose smallest allowed copy is still over the cap (SkyCut's floor below) is held at that copy and the
// others share what is left; when the held copies alone pass the total, the set is refused before anything is uploaded.
// Not here: each image's own limits (SkyStudioReferenceFit), pixels and files (SkyStudioReferenceImageFit). The total comes from
// /models; the floor is SkyCut's own rule for a reference that is still useful, not a model's limit.
// Rules: docs/architecture/reference-image-fitting.md.

enum SkyStudioReferenceTotal {
    /// SkyCut's floor for a copy made smaller to share a total: its long side stays at least this many pixels (an image already
    /// smaller keeps its size: never upscaled) and a JPEG keeps at least the quality the byte search starts from. Below it a
    /// reference loses most of its detail, so a set that would need less is refused instead.
    static let floorEdge = 512.0

    /// What one image of the set goes up as.
    enum Target: Equatable, Sendable {
        /// Its upload as it is: the original, or its copy fitted to its own limits.
        case keep
        /// A copy of at most this many bytes, as large as that allows.
        case cap(Double)
        /// Its smallest allowed copy: still over the cap there, so the others make up for it.
        case smallest
    }

    /// The targets for uploads of `sizes` bytes that must share `total`, in order; nil when even the smallest allowed copies of
    /// the images that must come down pass it. `smallest(i)` is image i's smallest allowed size in bytes, asked at most once
    /// and only for an image over the cap (it encodes a copy).
    static func share(_ sizes: [Double], total: Double, smallest: (Int) throws -> Double) rethrows -> [Target]? {
        var floors: [Int: Double] = [:]
        var held: [Int: Double] = [:]
        // Each pass holds at least one more image or ends: at most one pass per image. Holding an image above the cap only lowers
        // the cap of the others, so an image held once stays held.
        while true {
            let free = sizes.indices.filter { held[$0] == nil }
            let budget = total - held.values.reduce(0, +)
            guard budget >= 0 else { return nil }
            let cap = level(free.map { sizes[$0] }, budget: budget)
            var holding = false
            for index in free where sizes[index] > cap {
                if floors[index] == nil { floors[index] = min(sizes[index], try smallest(index)) }
                if let floor = floors[index], floor > cap {
                    held[index] = floor
                    holding = true
                }
            }
            if holding { continue }
            return sizes.indices.map { index in
                if let floor = held[index] { return floor < sizes[index] ? .smallest : .keep }
                return sizes[index] > cap ? .cap(cap) : .keep
            }
        }
    }

    /// The largest cap with Σ min(size, cap) ≤ budget: the largest sizes come down to it and the rest stay as they are;
    /// infinity when every size fits as it is.
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

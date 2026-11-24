import Foundation

// MARK: - One image of a reference set that shares a total, encoded for real (ImageIO, through SkyStudioReferenceImageFit.Source)
// What it does: gives SkyStudioReferenceTotal the real sizes of the copies one image can come down to, made from its snapshot:
// full-size steps first (a PNG written again, no pixel lost, once and only when the upload is still the user's own bytes; a
// JPEG's next lower quality, 0.92, 0.86, 0.8, after whatever its upload already has), then the largest size within a cap, never
// below SkyCut's floor (SkyStudioReferenceImageFit.floorScale). A copy is kept only when it is smaller than what the image has:
// an image never asked to step keeps its upload byte-identical. It keeps its chosen copy in memory; SkyStudioReferenceImageFit
// writes only the copies the set ends with. Blocking: on MediaReadQueue.analysis, through SkyStudioReferenceImageFit.prepare.
// Not here: which image steps when (SkyStudioReferenceTotal.share), the format and pixel scale (SkyStudioReferenceFit.decide).
// Rules: docs/architecture/reference-image-fitting.md.

struct SkyStudioReferenceSetImage: SkyStudioReferenceTotalImage {
    let file: SkyStudioReference
    let fit: SkyStudioReferenceFit
    /// How the image is written when it must come down (format, pixel scale); nil when it cannot be (an animation).
    let plan: SkyStudioReferenceFit.Plan?
    /// SkyCut's floor as a scale of the image.
    let lowest: Double
    /// Full-size qualities still to try (a PNG: one lossless write, its quality ignored).
    private(set) var steps: [Double]
    /// The copy the total chose; nil while the upload stays as it was.
    private(set) var copy: SkyStudioReferenceImageFit.Copy?
    private(set) var bytes: Double

    init(_ prepared: SkyStudioReferenceImageFit.Prepared, fit: SkyStudioReferenceFit) {
        file = prepared.file
        self.fit = fit
        bytes = Double(prepared.upload.bytes ?? Int(prepared.file.bytes))
        // Any byte cap below the image gives the same plan (format and pixel scale); 0 asks for it whatever the image's size.
        guard case .fit(let plan) = fit.capped(0).decide(prepared.file) else {
            self.plan = nil
            lowest = 1
            steps = []
            return
        }
        self.plan = plan
        lowest = SkyStudioReferenceImageFit.floorScale(prepared.file, plan: plan, fit: fit)
        let ownBytes = prepared.upload.url == prepared.snapshot?.url
        let qualities = SkyStudioReferenceImageFit.qualities
        if plan.contentType == "image/png" {
            // A PNG SkyCut already wrote would come out the same; the user's own may come out smaller (or larger, then kept).
            steps = ownBytes ? [qualities[0]] : []
        } else if let done = prepared.upload.quality {
            // A JPEG copy for its own limits: the qualities after its own, unless its size already came down (at the last one).
            steps = prepared.upload.scale == plan.scale ? qualities.filter { $0 < done } : []
        } else {
            steps = qualities
        }
    }

    mutating func step() throws -> Bool {
        guard let plan, !steps.isEmpty else { return false }
        let quality = steps.removeFirst()
        let source = try SkyStudioReferenceImageFit.Source(file, plan: plan, fit: fit)
        if let made = try source.encoded(plan.scale, quality: quality) { keepIfSmaller(made) }
        return true
    }

    mutating func shrink(to cap: Double) throws -> Bool {
        guard let plan else { return false }
        let source = try SkyStudioReferenceImageFit.Source(file, plan: plan, fit: fit)
        let quality = SkyStudioReferenceImageFit.qualities[SkyStudioReferenceImageFit.qualities.count - 1]
        if let found = try SkyStudioReferenceFit.largestFitting(below: plan.scale, lowest: lowest, firstBytes: Int(bytes), maxBytes: cap,
                                                               bytesOf: { $0.data.count }, encode: { try source.encoded($0, quality: quality) }) {
            keepIfSmaller(found)
            return true
        }
        // Even the floor is over the cap: keep whichever copy is smallest (a PNG at its floor can be larger than at full size).
        if let floor = try source.encoded(lowest, quality: quality) { keepIfSmaller(floor) }
        return false
    }

    private mutating func keepIfSmaller(_ made: SkyStudioReferenceImageFit.Copy) {
        guard Double(made.data.count) < bytes else { return }
        copy = made
        bytes = Double(made.data.count)
    }
}

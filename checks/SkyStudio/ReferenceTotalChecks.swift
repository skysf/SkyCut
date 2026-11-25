import Foundation
import SrtFlowMCPKit

// Reference images sharing a model's total for all of them (docs/architecture/reference-image-fitting.md, "A total for all the
// images"), the pure half: which limits apply (the total read from a record; every model of the chain bounds the copy, with
// fit_images or without; the chosen model's switch), how a set shares the total with real sizes (SkyStudioReferenceTotal.share
// over synthetic images: nothing touched within it, full-size steps the largest first and only while over, then sizes to the
// common cap, an image held at its floor, an image that cannot come down, a set that cannot be met), the exact floor, the byte
// search's floor, the AI's note, the reference check, the refusals and next steps. The ImageIO half is ReferenceTotalImageChecks.

/// A record with a total, as Sky Studio publishes one (fit_images).
func totalRecord(bytes: Double = 50_000_000, total: Double, fit: Bool = true, formats: JSONValue = fitFormats) -> SkyStudioModel {
    fitRecord("model", title: "Model", ["max_images": 4, "max_total_files": 4, "image_mime_types": formats, "max_image_bytes": .number(bytes),
                                        "max_total_image_bytes": .number(total), "image_dimensions": ["min_side": 15]], fit: fit)
}

func totalLimits(bytes: Double = 50_000_000, total: Double) -> SkyStudioReferenceFit {
    SkyStudioReferenceFit(model: totalRecord(bytes: bytes, total: total), mode: "images")!
}

/// A synthetic image for the sharing: the bytes each next full-size step gives, what its floor gives, and what was asked of it.
private struct FakeImage: SkyStudioReferenceTotalImage {
    var bytes: Double
    var steps: [Double] = []
    /// Bytes at SkyCut's floor; nil: it cannot come down by size at all (an animation).
    var floor: Double? = 0
    var asked: [String] = []

    mutating func step() -> Bool {
        guard !steps.isEmpty else { return false }
        asked.append("step")
        bytes = min(bytes, steps.removeFirst())
        return true
    }

    mutating func shrink(to cap: Double) -> Bool {
        asked.append("shrink")
        guard let floor else { return false }
        if floor <= cap { bytes = cap; return true }
        bytes = min(bytes, floor)
        return false
    }
}

func runReferenceTotalChecks() async {
    runReferenceTotalLimitChecks()
    runReferenceTotalShareChecks()
    runReferenceTotalWordChecks()
    await runReferenceTotalImageChecks()
}

private func runReferenceTotalLimitChecks() {
    // Which total applies.
    let seedream = fitRecord("seedream5-flash", title: "Seedream 5.0 Flash", [
        "max_images": 10, "max_total_files": 10, "max_image_bytes": 7_340_032, "max_total_image_bytes": 7_340_032, "image_mime_types": fitFormats,
        "max_image_pixels": 36_000_000, "image_dimensions": ["min_side": 15], "min_image_aspect_ratio": 0.0625, "max_image_aspect_ratio": 16])
    checkEqual(SkyStudioReferenceFit(model: seedream, mode: "images")?.maxTotalBytes, 7_340_032, "a record's max_total_image_bytes is read")
    checkEqual(SkyStudioReferenceFit(model: fitNano, mode: "images")?.maxTotalBytes, nil, "a record without one has no total (as before)")
    let chain = SkyStudioReferenceFit.strictest([fitNano, seedream], mode: "images")
    checkEqual(chain?.maxTotalBytes, 7_340_032, "the chain keeps a total only one model has")
    checkEqual(SkyStudioReferenceFit.strictest([totalRecord(total: 9_000_000), seedream], mode: "images")?.maxTotalBytes, 7_340_032, "two totals: the smaller")
    check(SkyStudioReferenceFit(model: totalRecord(total: 1_000, fit: false), mode: "images") == nil, "a total without fit_images is not fitted to")
    checkEqual(chain?.json["max_total_bytes"]?.doubleValue, 7_340_032, "the total is part of the limits' identity")
    check(chain?.json != SkyStudioReferenceFit.strictest([fitNano, fitSeedream], mode: "images")?.json,
          "an upload prepared without the total is not reused under it (official prepared references)")

    // Every model of the chain bounds the copy, fit_images or not (Codex review of #551: a fallback without fit_images was left
    // out, and a 368,991-byte JPEG went up as a 3,119,736-byte PNG over its 1,000,000).
    let pngOnly = fitRecord("png-only", title: "PNG Only", ["max_images": 4, "max_image_bytes": 31_457_280, "image_mime_types": ["image/png"]])
    let older = totalRecord(bytes: 1_000_000, total: 1_000_000, fit: false)
    let bounded = SkyStudioReferenceFit.strictest([pngOnly, older], mode: "images")
    checkEqual(bounded?.maxBytes, 1_000_000, "a fallback without fit_images still bounds each copy")
    checkEqual(bounded?.maxTotalBytes, 1_000_000, "and the set's total")
    checkEqual(bounded?.mimeTypes, ["image/png"], "and the formats every model takes")
    checkEqual(bounded?.modelTitles, ["PNG Only", "Model"], "both models are named in messages")
    check(SkyStudioReferenceFit.strictest([older, pngOnly], mode: "images") == nil, "fitting is the chosen model's switch: without it, upload as before")
    if case .fit(let plan)? = bounded?.decide(fitImage(800, 600, name: "photo.jpg", bytes: 368_991)) {
        checkEqual(plan.contentType, "image/png", "a JPEG becomes PNG only because a model refuses JPEG")
    } else { check(false, "a JPEG for a PNG-only model is fitted") }
    if case .fit(let plan)? = SkyStudioReferenceFit.strictest([fitNano, older], mode: "images")?.decide(fitImage(4000, 3000, bytes: 2_000_000)) {
        checkEqual(plan.contentType, "image/jpeg", "a JPEG over a fallback's byte limit stays JPEG while every model takes JPEG")
    } else { check(false, "a JPEG over a fallback's byte limit is fitted") }

    // The floor is exact: a long side of 512, never 511 (Codex review of #551: 561 × 480 came out 511 × 437).
    let plain = SkyStudioReferenceFit.Plan(contentType: "image/png", scale: 1, reasons: [])
    let odd = fitImage(561, 480, name: "odd.png", type: "image/png")
    if let bounded {
        let floorScale = SkyStudioReferenceImageFit.floorScale(odd, plan: plain, fit: bounded)
        let sized = bounded.size(width: 561, height: 480, scale: floorScale).map { [$0.width, $0.height] }
        checkEqual(sized, [512, 438], "561 × 480 at the floor is 512 × 438")
        checkEqual(SkyStudioReferenceImageFit.floorScale(fitImage(400, 300, type: "image/png"), plan: plain, fit: bounded), 1,
                   "an image already under the floor keeps its size: never upscaled")
    } else { check(false, "the bounded chain has limits") }

    // The reference check: a fit_images model shares its total at upload; an older record without fit_images refuses as before.
    let twoBig = SkyStudioReferencePlan(mode: "images", files: [fitImage(2000, 1000, name: "a.jpg", bytes: 5_000_000), fitImage(2000, 1000, name: "b.jpg", bytes: 5_000_000)])
    check(twoBig.problem(model: seedream) == nil, "over a fit_images model's total is not a reason to skip the model: the set is shared")
    check(twoBig.problem(model: totalRecord(total: 9_000_000, fit: false))?.contains("total image size limit (9000000 bytes)") == true,
          "without fit_images a set over the total is refused before upload, like the other limits")
    check(twoBig.problem(model: totalRecord(total: 10_000_000, fit: false)) == nil, "exactly at that total: taken")
    // The actual total beside the limit (MSG1 review, 2026-11-25): how much to drop.
    check(twoBig.problem(model: totalRecord(total: 9_000_000, fit: false))?.contains("The reference images total 10000000 bytes") == true,
          "the images' refusal gives their actual total")
    let allFiles = fitRecord("model", title: "Model", ["max_images": 4, "max_total_files": 4, "image_mime_types": fitFormats,
                                                       "max_image_bytes": 50_000_000, "max_total_bytes": 9_000_000, "image_dimensions": ["min_side": 15]], fit: false)
    checkEqual(twoBig.problem(model: allFiles), "The reference files total 10000000 bytes, over Model's total size limit (9000000 bytes).",
               "the files' total refusal gives the actual total and the limit")

    // What the AI is told before delivery.
    var three = SkyStudioReferencePlan(mode: "images", files: ["a", "b", "c"].map { fitImage(3000, 2000, name: "\($0).jpg", bytes: 3_000_000) })
    three.fit = chain
    let notes = SkyStudioReferenceFit.notes(three)
    check(notes.contains { $0.contains("about 9,000,000 bytes") && $0.contains("7,340,032 bytes") && $0.contains("512 px") && $0.contains("original files are unchanged") },
          "a set over the total: the note says so, with the total and the floor: \(notes)")
    three.files.removeLast()
    check(!SkyStudioReferenceFit.notes(three).contains { $0.contains("Together") }, "a set within the total: no such note")
}

private func runReferenceTotalShareChecks() {
    // The common cap: the largest c with Σ min(size, c) within the budget.
    checkEqual(SkyStudioReferenceTotal.level([1, 2, 7], budget: 6), 3, "the largest comes down to what the others leave")
    checkEqual(SkyStudioReferenceTotal.level([4, 4, 4], budget: 6), 2, "equal images share equally")
    checkEqual(SkyStudioReferenceTotal.level([1, 2, 3], budget: 6), .infinity, "exactly at the total: nothing comes down")
    checkEqual(SkyStudioReferenceTotal.level([3], budget: -1), 0, "no budget left: a cap of 0")

    func share(_ images: [FakeImage], _ total: Double) -> (fits: Bool, images: [FakeImage]) {
        var images = images
        let fits = (try? SkyStudioReferenceTotal.share(&images, total: total)) ?? false
        return (fits, images)
    }
    // Within the total nothing is asked of any image: every upload stays byte-identical.
    let within = share([FakeImage(bytes: 1, steps: [0.5]), FakeImage(bytes: 2, steps: [1]), FakeImage(bytes: 3, steps: [1])], 6)
    check(within.fits && within.images.allSatisfy { $0.asked.isEmpty }, "a set within the total: nothing re-encoded or shrunk")

    // Real sizes, full size first: the largest takes its next step and the set is measured again; once it fits, nothing else is
    // touched (Codex review of #551: a PNG was shrunk from 1,300 × 1,000 though the JPEG's real re-encode already made the set fit).
    let jpegFirst = share([FakeImage(bytes: 5, steps: [2], floor: 0.5), FakeImage(bytes: 4, steps: [3.9], floor: 0.5)], 8)
    check(jpegFirst.fits && jpegFirst.images[0].bytes == 2, "the largest (a JPEG) takes its quality step")
    check(jpegFirst.images[1].asked.isEmpty && jpegFirst.images[1].bytes == 4, "the PNG is never touched: the set already fits")
    // Ten PNGs, the last of which writes again at full size to 8,625 bytes but is 86,493 at its 512 px floor: the set fits at full
    // size (Codex review of #551: refused because the floor's bytes were taken as the smallest).
    var ten = (0 ..< 9).map { _ in FakeImage(bytes: 700_000, steps: [700_000], floor: 300_000) }
    ten.append(FakeImage(bytes: 900_000, steps: [8_625], floor: 86_493))
    let tenShared = share(ten, 9 * 700_000 + 40_204)
    check(tenShared.fits, "a set that fits once one PNG is written again at full size is not refused")
    check(tenShared.images.allSatisfy { !$0.asked.contains("shrink") }, "and nothing loses a pixel")
    check(tenShared.images.dropLast().allSatisfy { $0.asked.isEmpty }, "the nine other PNGs stay byte-identical")
    // A step that is not smaller is not kept (a PNG written again can come out larger).
    let larger = share([FakeImage(bytes: 4, steps: [5], floor: 1)], 3)
    check(larger.fits && larger.images[0].asked == ["step", "shrink"] && larger.images[0].bytes == 3, "a larger rewrite is dropped, then the size comes down")

    // Then sizes: the largest comes down to the common cap of what can still shrink, measured again each time, so both share it.
    let fair = share([FakeImage(bytes: 6, floor: 0.5), FakeImage(bytes: 6, floor: 0.5)], 7.34)
    check(fair.fits && fair.images.allSatisfy { abs($0.bytes - 3.67) < 0.000_001 }, "two equal images share the total equally (\(fair.images.map(\.bytes)))")
    // An image whose floor is over the cap keeps it; the other makes up for it.
    let held = share([FakeImage(bytes: 6, floor: 4.5), FakeImage(bytes: 5, floor: 1)], 8)
    check(held.fits && held.images[0].bytes == 4.5 && held.images[1].bytes == 3.5, "held at its floor, the other pays (\(held.images.map(\.bytes)))")
    // An image that cannot come down at all (an animation) stays as it is; the other pays.
    let stuck = share([FakeImage(bytes: 6, floor: nil), FakeImage(bytes: 4, floor: 0.5)], 7)
    check(stuck.fits && stuck.images[0].bytes == 6 && stuck.images[1].bytes == 1, "an animation stays, the other comes down (\(stuck.images.map(\.bytes)))")
    // Nothing can come down any further and the set is still over: refused.
    let unmet = share([FakeImage(bytes: 5, floor: 3), FakeImage(bytes: 5, floor: 3)], 5)
    check(!unmet.fits && unmet.images.allSatisfy { $0.bytes == 3 }, "the floors together over the total: refused")

    // The byte search never goes below its floor: an estimate under it tries the floor itself, and a floor still over is nil.
    var scales: [Double] = []
    let floored = SkyStudioReferenceFit.largestFitting(below: 1, lowest: 0.5, firstBytes: 100_000, maxBytes: 300, bytesOf: { $0.bytes }) {
        scale -> (scale: Double, bytes: Int)? in scales.append(scale); return (scale, Int(1_000 * scale * scale))
    }
    check((floored?.scale ?? 0) >= 0.5 && (floored?.bytes ?? .max) <= 300, "the largest copy at or over the floor (got \(floored?.scale ?? 0))")
    check(scales.allSatisfy { $0 >= 0.5 }, "no copy below the floor is even encoded (smallest asked: \(scales.min() ?? 0))")
    scales = []
    let over = SkyStudioReferenceFit.largestFitting(below: 1, lowest: 0.5, firstBytes: 100_000, maxBytes: 200, bytesOf: { $0.bytes }) {
        scale -> (scale: Double, bytes: Int)? in scales.append(scale); return (scale, Int(1_000 * scale * scale))
    }
    check(over == nil && scales.allSatisfy { $0 >= 0.5 }, "the floor's copy over the limit: nil, never a copy below the floor")
    check(scales.count <= 2, "and it gives up at the floor, not after twelve tries (\(scales.count))")
    // Bytes that barely fall until just above the floor: twelve small steps run out above it, then the floor itself is tried.
    let plateau = SkyStudioReferenceFit.largestFitting(below: 1, lowest: 0.5, firstBytes: 533, maxBytes: 300, bytesOf: { $0.bytes }) {
        scale -> (scale: Double, bytes: Int)? in (scale, scale > 0.505 ? 301 : 250)
    }
    check((plateau?.scale ?? 0) >= 0.5 && (plateau?.bytes ?? .max) <= 300, "a copy that fits at the floor is found after a long plateau")
}

private func runReferenceTotalWordChecks() {
    // SkyCut's refusal names the combined limit, the floor and the files; the user's words are SkyStudioReferenceFitWords.
    let failure = SkyStudioReferenceFitFailure(file: "a.png, b.png, c.png", models: ["Seedream 5.0 Flash"], reason: .tooLargeTogether(total: 7_340_032, count: 3))
    check(failure.message.contains("3 reference images (a.png, b.png, c.png)") && failure.message.contains("at most 7,340,032 bytes for all of them")
          && failure.message.contains("512 px") && failure.message.contains("Nothing was sent or charged"), "the refusal: \(failure.message)")
    // The official preparation's get_job, and Sky Studio's own refusal (/jobs, too_large_together: a character's views count there).
    check(SkyStudioReferenceFitFailure.preparedNextStep.contains("Nothing was uploaded, reserved or charged")
          && SkyStudioReferenceFitFailure.preparedNextStep.contains("prepare_references=true"), "the prepared references' next step says what to change")
    let refused = SkyStudioJobFailure(message: "Reference images 1 to 3 are 8,917,941 bytes together; this model takes at most 7,340,032 for all of them. Nothing was charged.",
                                      fields: ["code": "invalid_request", "reason": "too_large_together", "reference": 3, "limit": 7_340_032])
    checkEqual(refused.limit, 7_340_032, "a /jobs refusal's limit is read")
    checkEqual(refused.json["limit"]?.doubleValue, 7_340_032, "and shown to the AI")
    let next = SkyStudioReferenceFitFailure.togetherNextStep(limit: refused.limit)
    check(next.contains("7,340,032 bytes for all of them") && next.contains("a character's views included") && next.contains("Nothing was submitted or charged")
          && next.contains("character_roles") && next.contains("new idempotency_key") && !next.contains("Query this original job"),
          "its next step says nothing was submitted or charged and what to change: \(next)")
    // The guide tells the AI the same: an over-total refusal reports the combined limit, and a character's views count on the server.
    let inputs = MCPGuide.answer(topic: "generate_media", section: "inputs").encodedString()
    check(inputs.contains("refused with the combined limit") && inputs.contains("A character's views also count toward")
          && inputs.contains("re-encodes at full size first"), "generate_media's inputs say how the total is shared and refused")
}

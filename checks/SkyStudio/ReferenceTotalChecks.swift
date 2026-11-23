import Foundation
import SrtFlowMCPKit

// Reference images sharing a model's total for all of them (docs/architecture/reference-image-fitting.md, "A total for all the
// images"). The pure half: which total applies (only from a fit_images record; the strictest of a chain), how a set shares it
// (SkyStudioReferenceTotal: the largest first, down to one cap; the rest untouched; an image held at its smallest copy; a set
// that cannot be met), the byte search's floor, the AI's note, the reference check and the refusal. The ImageIO half: real
// files fitted as a set (one image over the total, three whose sum is over, one that cannot come down, a set that cannot be
// met), read back after. Synthetic limits keep the files small; Sky Studio's own records are checked in ReferenceFitChecks.

/// A record with a total, as Sky Studio publishes one (fit_images).
private func totalRecord(bytes: Double = 50_000_000, total: Double, fit: Bool = true) -> SkyStudioModel {
    fitRecord("model", title: "Model", ["max_images": 4, "max_total_files": 4, "image_mime_types": fitFormats, "max_image_bytes": .number(bytes),
                                        "max_total_image_bytes": .number(total), "image_dimensions": ["min_side": 15]], fit: fit)
}

private func totalLimits(bytes: Double = 50_000_000, total: Double) -> SkyStudioReferenceFit {
    SkyStudioReferenceFit(model: totalRecord(bytes: bytes, total: total), mode: "images")!
}

func runReferenceTotalChecks() async {
    runReferenceTotalPlanChecks()
    await runReferenceTotalImageChecks()
}

private func runReferenceTotalPlanChecks() {
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

    // The common cap: the largest c with Σ min(size, c) within the budget.
    checkEqual(SkyStudioReferenceTotal.level([1, 2, 7], budget: 6), 3, "the largest comes down to what the others leave")
    checkEqual(SkyStudioReferenceTotal.level([4, 4, 4], budget: 6), 2, "equal images share equally")
    checkEqual(SkyStudioReferenceTotal.level([1, 2, 3], budget: 6), .infinity, "exactly at the total: nothing comes down")

    // How a set shares it.
    var asked: [Int] = []
    let fits = SkyStudioReferenceTotal.share([1, 2, 3], total: 6) { asked.append($0); return 0.1 }
    checkEqual(fits, [.keep, .keep, .keep], "a set within the total stays as it is")
    checkEqual(asked, [], "and nothing is encoded to find out")
    asked = []
    let largest = SkyStudioReferenceTotal.share([1, 2, 7], total: 6) { asked.append($0); return 0.5 }
    checkEqual(largest, [.keep, .keep, .cap(3)], "only the largest comes down, to the cap: the small ones stay byte-identical")
    checkEqual(asked, [2], "only the image over the cap is asked for its smallest copy")
    let two = SkyStudioReferenceTotal.share([1, 5, 7], total: 9) { _ in 0.5 }
    checkEqual(two, [.keep, .cap(4), .cap(4)], "two over: both come down to one cap (fair, the largest first)")
    // The 7-byte image cannot go below 4.5 (SkyCut's floor): held there, the 5-byte one makes up for it.
    let held = SkyStudioReferenceTotal.share([1, 5, 7], total: 8) { $0 == 2 ? 4.5 : 1 }
    checkEqual(held, [.keep, .cap(2.5), .smallest], "an image whose smallest copy is over the cap is held at it; the others share the rest")
    let stuck = SkyStudioReferenceTotal.share([2, 6], total: 7) { $0 == 1 ? 6.5 : 0.5 }
    checkEqual(stuck, [.cap(1), .keep], "an image that cannot be made smaller stays as it is (never a bigger copy); the other pays")
    asked = []
    let impossible = SkyStudioReferenceTotal.share([5, 5, 5], total: 6) { asked.append($0); return 3 }
    checkEqual(impossible, nil, "the smallest copies together over the total: refused")
    checkEqual(asked, [0, 1, 2], "each image asked once")

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

    // What the AI is told before delivery.
    var three = SkyStudioReferencePlan(mode: "images", files: ["a", "b", "c"].map { fitImage(3000, 2000, name: "\($0).jpg", bytes: 3_000_000) })
    three.fit = chain
    let notes = SkyStudioReferenceFit.notes(three)
    check(notes.contains { $0.contains("about 9,000,000 bytes") && $0.contains("7,340,032 bytes") && $0.contains("512 px") && $0.contains("original files are unchanged") },
          "a set over the total: the note says so, with the total and the floor: \(notes)")
    three.files.removeLast()
    check(!SkyStudioReferenceFit.notes(three).contains { $0.contains("Together") }, "a set within the total: no such note")

    // The reference check: a fit_images model shares its total at upload; an older record without fit_images refuses as before.
    let twoBig = SkyStudioReferencePlan(mode: "images", files: [fitImage(2000, 1000, name: "a.jpg", bytes: 5_000_000), fitImage(2000, 1000, name: "b.jpg", bytes: 5_000_000)])
    check(twoBig.problem(model: seedream) == nil, "over a fit_images model's total is not a reason to skip the model: the set is shared")
    check(twoBig.problem(model: totalRecord(total: 9_000_000, fit: false))?.contains("total image size limit (9000000 bytes)") == true,
          "without fit_images a set over the total is refused before upload, like the other limits")
    check(twoBig.problem(model: totalRecord(total: 10_000_000, fit: false)) == nil, "exactly at that total: taken")

    // The refusal names the total, the floor and the files; the user's words are SkyStudioReferenceFitWords (localized).
    let failure = SkyStudioReferenceFitFailure(file: "a.png, b.png, c.png", models: ["Seedream 5.0 Flash"], reason: .tooLargeTogether(total: 7_340_032, count: 3))
    check(failure.message.contains("3 reference images (a.png, b.png, c.png)") && failure.message.contains("at most 7,340,032 bytes for all of them")
          && failure.message.contains("512 px") && failure.message.contains("Nothing was sent or charged"), "the refusal: \(failure.message)")
}

private func runReferenceTotalImageChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-reference-total-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = FitFixture(folder: folder)
    let output = folder.appendingPathComponent("out", isDirectory: true)
    let size = { (url: URL) in ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? -1 }
    let leftovers = { (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] }
    let longSide = { (upload: SkyStudioReferenceImageFit.Upload) in readBack(upload.url).map { max($0.width, $0.height) } ?? 0 }

    // One image over the total (within its own byte limit) comes down to the total alone.
    let photo = fixture.write(fixture.picture(900, 600, noise: true), "photo.jpg", type: .jpeg)
    let photoImage = fixture.measured(photo)
    checkEqual((try? await SkyStudioReferenceImageFit.prepare([photoImage], fit: totalLimits(total: photoImage.bytes), folder: output))?.first?.url,
               photo, "exactly at the total: the original")
    let alone = (photoImage.bytes * 0.6).rounded()
    if let sent = try? await SkyStudioReferenceImageFit.prepare([photoImage], fit: totalLimits(total: alone), folder: output), let copy = sent.first,
       let back = readBack(copy.url) {
        check(copy.temporary && Double(copy.bytes ?? .max) <= alone, "one image over the total goes up as a copy within it (\(copy.bytes ?? -1) ≤ \(Int(alone)))")
        checkEqual(back.type, "image/jpeg", "a JPEG stays JPEG")
        check(back.width <= 900 && abs(Double(back.width) / Double(back.height) - 1.5) < 0.01, "never larger, same shape (\(back.width)×\(back.height))")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "one image over the total is fitted to it") }
    checkEqual(size(photo), photoImage.bytes, "the original file is unchanged")

    // Three images whose sum is over: the small one stays byte-identical, the two large come down to one cap, as little as needed.
    // The large photo is also over its own byte limit: its copy for that is replaced by one from the original, and removed.
    let small = fixture.write(fixture.picture(300, 200), "small.png", type: .png)
    let cutout = fixture.write(fixture.picture(800, 600, noise: true, alpha: true), "cutout.png", type: .png)
    let large = fixture.write(fixture.picture(1200, 900, noise: true), "large.jpg", type: .jpeg)
    let set = [small, cutout, large].map(fixture.measured)
    let ownBytes = (set[2].bytes * 0.9).rounded()
    var own: [Double] = []  // what each image goes up as against its own limits alone (the single prepare reads no total)
    for file in set {
        let alone = try? await SkyStudioReferenceImageFit.prepare(file, fit: totalLimits(bytes: ownBytes, total: 1), folder: output)
        own.append(Double(alone?.bytes ?? -1))
        alone?.cleanUp()
    }
    let total = (own[0] + 0.6 * (own[1] + own[2])).rounded()
    let limits = totalLimits(bytes: ownBytes, total: total)
    let cap = SkyStudioReferenceTotal.level(own, budget: total)
    check(own[2] < set[2].bytes && own[2] > cap, "the large photo is first fitted to its own byte limit, still over the cap (\(own) of \(set.map(\.bytes)), cap \(Int(cap)))")
    check(cap > own[0] && cap < min(own[1], own[2]), "the fixture's cap lies between the small image and the two large ones")
    if let sent = try? await SkyStudioReferenceImageFit.prepare(set, fit: limits, folder: output), sent.count == 3 {
        check(sent[0].url == small && !sent[0].temporary, "the small image under the cap goes up as it is, byte-identical")
        check(sent[1].temporary && Double(sent[1].bytes ?? .max) <= cap, "the cutout comes down to the common cap (\(sent[1].bytes ?? -1) ≤ \(Int(cap)))")
        check(sent[2].temporary && Double(sent[2].bytes ?? .max) <= cap, "the large photo too (\(sent[2].bytes ?? -1) ≤ \(Int(cap)))")
        let sum = sent.compactMap(\.bytes).reduce(0, +)
        check(sent.allSatisfy { $0.bytes != nil } && Double(sum) <= total, "the set is within the total (\(sum) ≤ \(Int(total)))")
        check(Double(sent[1].bytes ?? 0) >= 0.9 * cap, "the PNG keeps as much as the cap allows, no more cut than needed (\(sent[1].bytes ?? -1) of \(Int(cap)))")
        if let back = readBack(sent[1].url) {
            checkEqual(back.type, "image/png", "the cutout stays PNG")
            check(back.alpha, "with its alpha")
            check(abs(Double(back.width) / Double(back.height) - 4.0 / 3.0) < 0.01, "and its shape (\(back.width)×\(back.height))")
        } else { check(false, "the cutout's copy reads back") }
        checkEqual(readBack(sent[2].url)?.type, "image/jpeg", "the photo stays JPEG")
        check(sent.dropFirst().allSatisfy { longSide($0) >= 512 }, "neither copy goes below SkyCut's floor (a 512 px long side)")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "three images over the total together are shared") }
    check([small, cutout, large].enumerated().allSatisfy { size($0.element) == set[$0.offset].bytes }, "the original files are unchanged")
    checkEqual(leftovers(), [], "every copy is removed after the upload")

    // An image that cannot come down (a PNG already under the floor: no smaller size, no quality to give) keeps its size; the
    // other image makes up for it.
    let tight = fixture.write(fixture.picture(500, 400, noise: true), "tight.png", type: .png)
    let wide = fixture.write(fixture.picture(1600, 1200, noise: true), "wide.jpg", type: .jpeg)
    let pair = [tight, wide].map(fixture.measured)
    let wideFloor = Double((try? SkyStudioReferenceImageFit.smallestCopy(pair[1], fit: totalLimits(total: 1)))??.copy.data.count ?? 0)
    let pairTotal = (pair[0].bytes + 1.2 * wideFloor).rounded()
    check(wideFloor > 0 && 1.2 * wideFloor < pair[0].bytes && pair[1].bytes > pair[0].bytes, "the fixture holds the PNG (its share is under its size)")
    if let sent = try? await SkyStudioReferenceImageFit.prepare(pair, fit: totalLimits(total: pairTotal), folder: output), sent.count == 2 {
        check(readBack(sent[0].url).map { $0.width == 500 && $0.height == 400 } == true && (sent[0].bytes ?? .max) <= Int(pair[0].bytes),
              "the PNG that cannot come down keeps its size (as it is, or the same pixels written smaller)")
        let left = pairTotal - Double(sent[0].bytes ?? 0)
        check(sent[1].temporary && Double(sent[1].bytes ?? .max) <= left, "the photo takes what is left (\(sent[1].bytes ?? -1) ≤ \(Int(left)))")
        check(longSide(sent[1]) >= 512, "not below the floor")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set with an image that cannot come down is shared by the others") }

    // A set that cannot be met: three noisy PNGs whose smallest copies (a 512 px long side) are together over the total.
    let heavy = (1 ... 3).map { fixture.measured(fixture.write(fixture.picture(900, 600, noise: true), "heavy\($0).png", type: .png)) }
    let floorBytes = Double((try? SkyStudioReferenceImageFit.smallestCopy(heavy[0], fit: totalLimits(total: 1)))??.copy.data.count ?? 0)
    check(floorBytes > 0 && floorBytes * 3 < heavy.map(\.bytes).reduce(0, +), "the fixture's smallest copies are smaller than the originals")
    // The byte search reaches that smallest copy: capped at its bytes, a copy is still found (one decode path for both).
    let anyTotal = totalLimits(total: 1)
    if case .fit(let plan) = anyTotal.capped(0).decide(heavy[0]) {
        let exact = try? SkyStudioReferenceImageFit.write(heavy[0], plan: plan, fit: anyTotal.capped(floorBytes), folder: output,
                                                          lowest: SkyStudioReferenceImageFit.floorScale(heavy[0], plan: plan, fit: anyTotal))
        check((exact?.bytes).map { Double($0) <= floorBytes } == true, "capped at the smallest copy's bytes, the search finds a copy (\(exact?.bytes ?? -1) ≤ \(Int(floorBytes)))")
        exact?.cleanUp()
    } else { check(false, "a heavy PNG has a plan to come down") }
    let unmet = (floorBytes * 3 * 0.9).rounded()
    do {
        _ = try await SkyStudioReferenceImageFit.prepare(heavy, fit: totalLimits(total: unmet), folder: output)
        check(false, "a set that cannot be met is refused")
    } catch let failure as SkyStudioReferenceFitFailure {
        checkEqual(failure.reason, .tooLargeTogether(total: unmet, count: 3), "refused as too large together, with the total")
        check(failure.message.contains("at most \(SkyStudioReferenceFit.text(unmet)) bytes for all of them") && failure.message.contains("512 px"),
              "the refusal names the total and the floor: \(failure.message)")
        check(failure.file.contains("heavy1.png") && failure.file.contains("heavy3.png"), "and the files: \(failure.file)")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }
    checkEqual(leftovers(), [], "a refused set leaves no copy behind")
    let enough = (floorBytes * 3 * 1.03).rounded()
    if let sent = try? await SkyStudioReferenceImageFit.prepare(heavy, fit: totalLimits(total: enough), folder: output) {
        check(Double(sent.compactMap(\.bytes).reduce(0, +)) <= enough, "with room for the smallest copies the same set is shared")
        check(sent.allSatisfy { longSide($0) >= 512 }, "and no copy goes below the floor (\(sent.map(longSide)))")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set just over its smallest copies is shared") }

    // A refusal while the set is prepared (the second image is too small) removes the copy already made for the first.
    let tiny = fixture.write(fixture.picture(10, 10), "tiny.png", type: .png)
    do {
        _ = try await SkyStudioReferenceImageFit.prepare([photoImage, fixture.measured(tiny)], fit: totalLimits(bytes: alone, total: alone * 2), folder: output)
        check(false, "a set with an image below the minimum side is refused")
    } catch is SkyStudioReferenceFitFailure {
        checkEqual(leftovers(), [], "the first image's copy is removed when a later one is refused")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }

    // Without a total the set goes as each image alone (an older Sky Studio record, or a model without one).
    var noTotal = totalLimits(total: 1)
    noTotal.maxTotalBytes = nil
    checkEqual((try? await SkyStudioReferenceImageFit.prepare(set, fit: noTotal, folder: output))?.map(\.url), [small, cutout, large],
               "no total: every image within its own limits goes as it is")
}

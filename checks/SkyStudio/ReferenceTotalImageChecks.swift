import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SrtFlowMCPKit

// Reference images sharing a model's total, the ImageIO half (docs/architecture/reference-image-fitting.md, "A total for all
// the images"): real files fitted as a set and read back. One image over the total; three whose sum is over; a JPEG whose real
// re-encode makes the set fit, so the PNG beside it is never touched; a PNG written again at full size, no pixel lost; an image
// that cannot come down while the other pays; the exact floor; a set that cannot be met; a fallback without fit_images bounding
// a converted copy; a file changed between the check and the upload; a refusal mid-set. Nothing here reads the user's files.

/// What a file holds now (nil when it is gone).
private func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }

func runReferenceTotalImageChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-reference-total-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = FitFixture(folder: folder)
    let output = folder.appendingPathComponent("out", isDirectory: true)
    let leftovers = { (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] }
    let longSide = { (upload: SkyStudioReferenceImageFit.Upload) in readBack(upload.url).map { max($0.width, $0.height) } ?? 0 }
    let prepare = { (files: [SkyStudioReference], fit: SkyStudioReferenceFit) in try? await SkyStudioReferenceImageFit.prepare(files, fit: fit, folder: output) }

    // One image over the total (within its own byte limit) comes down to the total alone.
    let photo = fixture.write(fixture.picture(900, 600, noise: true), "photo.jpg", type: .jpeg)
    let photoImage = fixture.measured(photo)
    if let exact = await prepare([photoImage], totalLimits(total: photoImage.bytes))?.first {
        check(contents(exact.url) == contents(photo) && exact.url != photo, "exactly at the total: the original's bytes, from a stable copy")
        exact.cleanUp()
    } else { check(false, "an image exactly at the total is prepared") }
    let alone = (photoImage.bytes * 0.6).rounded()
    if let copy = await prepare([photoImage], totalLimits(total: alone))?.first, let back = readBack(copy.url) {
        check(Double(copy.bytes ?? .max) <= alone, "one image over the total goes up within it (\(copy.bytes ?? -1) ≤ \(Int(alone)))")
        checkEqual(back.type, "image/jpeg", "a JPEG stays JPEG")
        check(back.width <= 900 && abs(Double(back.width) / Double(back.height) - 1.5) < 0.01, "never larger, same shape (\(back.width)×\(back.height))")
        copy.cleanUp()
    } else { check(false, "one image over the total is fitted to it") }

    // A JPEG whose real re-encode makes the set fit: the PNG beside it goes up byte-identical (Codex review of #551: one cap split
    // before encoding shrank such a PNG from 1,300 × 1,000 to 1,260 × 969).
    let cutout = fixture.write(fixture.picture(1100, 750, noise: true, alpha: true), "cutout.png", type: .png)
    let heavy = fixture.write(fixture.picture(1200, 900, noise: true), "heavy.jpg", type: .jpeg)
    let pair = [cutout, heavy].map(fixture.measured)
    let pairTotal = (pair[0].bytes + 0.5 * pair[1].bytes).rounded()
    check(pair[1].bytes > pair[0].bytes && SkyStudioReferenceTotal.level(pair.map(\.bytes), budget: pairTotal) < pair[0].bytes,
          "the fixture: the JPEG is the largest, and one cap split up front would have shrunk the PNG too")
    if let sent = await prepare(pair, totalLimits(total: pairTotal)), sent.count == 2 {
        check(contents(sent[0].url) == contents(cutout), "the PNG goes up byte-identical: the JPEG's own step was enough")
        check(Double(sent.compactMap(\.bytes).reduce(0, +)) <= pairTotal, "the set is within the total")
        checkEqual(readBack(sent[1].url).map { [$0.width, $0.height] }, [1200, 900], "the JPEG kept its size: a little quality was enough")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set fitted by one JPEG step is shared") }

    // A PNG written again at full size, no pixel lost, makes the set fit: no image is shrunk (a PNG saved without filters is about
    // ten times larger than ImageIO writes the same pixels).
    let gradient = fixture.picture(1300, 1000, gradient: true)
    let loose = fixture.write(gradient, "loose.png", type: .png, pngFilter: 0x08)
    let other = fixture.write(fixture.picture(500, 400, noise: true), "other.png", type: .png)
    let lossless = [loose, other].map(fixture.measured)
    let losslessTotal = (lossless[1].bytes + 0.5 * lossless[0].bytes).rounded()
    if let sent = await prepare(lossless, totalLimits(total: losslessTotal)), sent.count == 2, let back = readBack(sent[0].url) {
        checkEqual([back.width, back.height], [1300, 1000], "the loose PNG keeps its full size")
        check(Double(sent[0].bytes ?? .max) < lossless[0].bytes / 2, "written again, it is a fraction of its file (\(sent[0].bytes ?? -1))")
        check(contents(sent[1].url) == contents(other), "the other PNG goes up byte-identical")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set fitted by one PNG written again is shared") }

    // Three images whose sum is over: the small one stays byte-identical, the large come down; the large photo's copy for its own
    // byte limit is replaced by one from its original, and removed.
    let small = fixture.write(fixture.picture(300, 200), "small.png", type: .png)
    let large = fixture.write(fixture.picture(1200, 900, noise: true), "large.jpg", type: .jpeg)
    let set = [small, cutout, large].map(fixture.measured)
    let ownBytes = (set[2].bytes * 0.9).rounded()
    let setTotal = (set[0].bytes + 0.25 * (set[1].bytes + set[2].bytes)).rounded()
    if let sent = await prepare(set, totalLimits(bytes: ownBytes, total: setTotal)), sent.count == 3 {
        check(contents(sent[0].url) == contents(small), "the small image goes up byte-identical")
        check(Double(sent.compactMap(\.bytes).reduce(0, +)) <= setTotal, "the set is within the total (\(sent.compactMap(\.bytes).reduce(0, +)) ≤ \(Int(setTotal)))")
        if let back = readBack(sent[1].url) {
            checkEqual(back.type, "image/png", "the cutout stays PNG")
            check(back.alpha && abs(Double(back.width) / Double(back.height) - 1100.0 / 750) < 0.01, "with its alpha and shape (\(back.width)×\(back.height))")
        } else { check(false, "the cutout's copy reads back") }
        checkEqual(readBack(sent[2].url)?.type, "image/jpeg", "the photo stays JPEG")
        check(sent.dropFirst().allSatisfy { longSide($0) >= 512 }, "no copy goes below SkyCut's floor (a 512 px long side)")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "three images over the total together are shared") }
    check([small, cutout, large].enumerated().allSatisfy { contents($0.element).map { Double($0.count) } == set[$0.offset].bytes }, "the originals are unchanged")
    checkEqual(leftovers(), [], "every snapshot and copy is removed after the upload")

    // An image under the floor that cannot come down keeps its size; the other pays. The floor is exact: the first image, held at
    // its floor, is 512 × 438 (Codex review of #551: 561 × 480 came out 511 × 437).
    let odd = fixture.measured(fixture.write(fixture.picture(561, 480, noise: true), "odd.png", type: .png))
    let wide = fixture.measured(fixture.write(fixture.picture(1600, 1200, noise: true), "wide.jpg", type: .jpeg))
    let anyTotal = totalLimits(total: 1)
    func floorBytes(_ file: SkyStudioReference) -> Double {
        guard case .fit(let plan) = anyTotal.capped(0).decide(file), let source = try? SkyStudioReferenceImageFit.Source(file, plan: plan, fit: anyTotal),
              let copy = try? source.encoded(SkyStudioReferenceImageFit.floorScale(file, plan: plan, fit: anyTotal), quality: 0.8) else { return 0 }
        return Double(copy.data.count)
    }
    let oddFloor = floorBytes(odd), wideFloor = floorBytes(wide)
    let heldTotal = (oddFloor + 1.5 * wideFloor).rounded()
    check(oddFloor > 0 && wideFloor > 0 && oddFloor < odd.bytes, "the fixture's floors are known")
    if let sent = await prepare([odd, wide], totalLimits(total: heldTotal)), sent.count == 2 {
        checkEqual(readBack(sent[0].url).map { [$0.width, $0.height] }, [512, 438], "held at its floor, exactly a 512 px long side")
        check(Double(sent.compactMap(\.bytes).reduce(0, +)) <= heldTotal, "the set is within the total")
        check(longSide(sent[1]) >= 512, "the other image paid, not below the floor")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set with an image held at its floor is shared") }

    // A set that cannot be met: three noisy PNGs whose floor copies are together over the total. Refused, nothing left behind.
    let three = (1 ... 3).map { fixture.measured(fixture.write(fixture.picture(900, 600, noise: true), "dense\($0).png", type: .png)) }
    let unmet = (floorBytes(three[0]) * 3 * 0.9).rounded()
    do {
        _ = try await SkyStudioReferenceImageFit.prepare(three, fit: totalLimits(total: unmet), folder: output)
        check(false, "a set that cannot be met is refused")
    } catch let failure as SkyStudioReferenceFitFailure {
        checkEqual(failure.reason, .tooLargeTogether(total: unmet, count: 3), "refused as too large together, with the combined limit")
        check(failure.file.contains("dense1.png") && failure.file.contains("dense3.png"), "naming the user's files: \(failure.file)")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }
    checkEqual(leftovers(), [], "a refused set leaves no snapshot or copy behind")

    // A fallback without fit_images bounds a converted copy: a JPEG for a PNG-only model stays within the fallback's 1,000,000 bytes.
    let pngOnly = fitRecord("png-only", title: "PNG Only", ["max_images": 4, "max_image_bytes": 31_457_280, "image_mime_types": ["image/png"]])
    let bounded = SkyStudioReferenceFit.strictest([pngOnly, totalRecord(bytes: 1_000_000, total: 1_000_000, fit: false)], mode: "images")
    let dense = fixture.measured(fixture.write(fixture.picture(800, 600, noise: true), "dense.jpg", type: .jpeg, quality: 0.5))
    if let bounded, let copy = await prepare([dense], bounded)?.first {
        checkEqual(copy.contentType, "image/png", "converted because the chosen model takes only PNG")
        check(Double(copy.bytes ?? .max) <= 1_000_000, "and within the fallback's 1,000,000 bytes (\(copy.bytes ?? -1))")
        copy.cleanUp()
    } else { check(false, "a JPEG for a PNG-only chain is fitted") }

    // A step that comes out larger is not kept: a JPEG saved at quality 0.5 grows when written again at 0.92.
    let lowURL = fixture.write(fixture.picture(800, 600, noise: true), "low.jpg", type: .jpeg, quality: 0.5)
    let low = fixture.measured(lowURL)
    let own = SkyStudioReferenceImageFit.Upload(url: lowURL, contentType: "image/jpeg", temporary: false, bytes: Int(low.bytes))
    var lowImage = SkyStudioReferenceSetImage(SkyStudioReferenceImageFit.Prepared(file: low, upload: own, snapshot: own), fit: anyTotal)
    let stepped = try? lowImage.step()
    check(stepped == true && lowImage.copy == nil && lowImage.bytes == low.bytes, "a quality step that comes out larger is not kept (\(lowImage.bytes))")

    await runReferenceSnapshotChecks(fixture, output: output, leftovers: leftovers)
}

/// What goes up is what was checked: a file rewritten (bigger, or as a TIFF) after the check still goes up as checked, labelled as
/// checked, and the uploads together stay within the total (Codex review of #551: 8,110,710 bytes went up over a 7,340,032 total,
/// and a TIFF went up labelled image/png).
private func runReferenceSnapshotChecks(_ fixture: FitFixture, output: URL, leftovers: () -> [String]) async {
    let first = fixture.write(fixture.picture(600, 400, noise: true), "first.png", type: .png)
    let second = fixture.write(fixture.picture(600, 400, noise: true, alpha: true), "second.png", type: .png)
    let set = [first, second].map(fixture.measured)
    let total = (set[0].bytes + set[1].bytes) * 1.01
    let checked = contents(second)
    guard let sent = try? await SkyStudioReferenceImageFit.prepare(set, fit: totalLimits(total: total), folder: output), sent.count == 2 else {
        return check(false, "a set within the total is prepared")
    }
    let api = SkyStudioAPI(session: SkyStudioStub.session)
    SkyStudioStub.reset { seen in
        seen.url.hasSuffix("/uploads")
            ? .http(200, #"{"upload_url": "http://127.0.0.1:8124/r2/up", "method": "PUT", "headers": {"Content-Type": "image/png"}, "file_url": "https://r2.example/originals/u/skycut/up.png"}"#)
            : .http(200, "")
    }
    let key = "sk-" + String(repeating: "f", count: 43)
    _ = try? await api.upload(fileURL: sent[0].url, contentType: sent[0].contentType ?? "", purpose: "image", key: key) { _ in }
    // Right after the first upload the user's second file is replaced by a much larger picture, then by a TIFF at the same path.
    _ = fixture.write(fixture.picture(1600, 1200, noise: true), "second.png", type: .png)
    _ = fixture.write(fixture.picture(600, 400), "second.png", type: .tiff)
    check(contents(sent[1].url) == checked, "the second upload is the bytes that were checked, not the file as it is now")
    checkEqual(sent[1].contentType, "image/png", "labelled as it was checked")
    _ = try? await api.upload(fileURL: sent[1].url, contentType: sent[1].contentType ?? "", purpose: "image", key: key) { _ in }
    let puts = SkyStudioStub.log.filter { $0.method == "PUT" }.compactMap(\.body)
    checkEqual(puts.count, 2, "both uploads reached the fake storage")
    check(puts.last == checked && Double(puts.reduce(0) { $0 + $1.count }) <= total, "the PUTs carry the checked bytes, within the total")
    sent.forEach { $0.cleanUp() }

    // A refusal while the set is prepared (the second image is too small) removes the snapshot and copy made for the first.
    let tiny = fixture.measured(fixture.write(fixture.picture(10, 10), "tiny.png", type: .png))
    let bigger = fixture.measured(fixture.write(fixture.picture(900, 600, noise: true), "bigger.jpg", type: .jpeg))
    do {
        _ = try await SkyStudioReferenceImageFit.prepare([bigger, tiny], fit: totalLimits(bytes: bigger.bytes * 0.6, total: bigger.bytes * 2), folder: output)
        check(false, "a set with an image below the minimum side is refused")
    } catch is SkyStudioReferenceFitFailure {
        checkEqual(leftovers(), [], "the first image's snapshot and copy are removed when a later one is refused")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }

    // Without a total the set goes as each image alone: the checked bytes, from stable copies.
    var noTotal = totalLimits(total: 1)
    noTotal.maxTotalBytes = nil
    if let sent = try? await SkyStudioReferenceImageFit.prepare([fixture.measured(first)], fit: noTotal, folder: output) {
        check(contents(sent[0].url) == contents(first) && sent[0].url != first, "no total: within its own limits it goes as it is, from a stable copy")
        sent.forEach { $0.cleanUp() }
    } else { check(false, "a set without a total is prepared") }
    checkEqual(leftovers(), [], "nothing is left behind")
}

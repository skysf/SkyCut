import Foundation
import SrtFlowMCPKit

// Reference images fitted to the published limits (docs/architecture/reference-image-fitting.md), the pure half: which limits
// apply (only a record with fit_images; the strictest of the chosen model and its fallbacks), what happens to one image at,
// above and below each limit, the chain SkyCut picks, the reference check and the AI's note. The records mirror what Sky Studio
// publishes (its shared/skycutReferenceImageLimits.ts); SkyCut's own code writes none of these numbers.

/// An image record as Sky Studio publishes it; `fit: false` is an older Sky Studio (no fit_images).
func fitRecord(_ id: String, title: String, _ references: [String: JSONValue], fit: Bool = true, operation: String? = nil) -> SkyStudioModel {
    var limits = references
    limits["max_videos"] = 0
    limits["max_audio"] = 0
    if fit { limits["fit_images"] = true }
    var model = SkyStudioModel(id: id, kind: "image", title: title, params: ["resolution": ["2K"], "aspect_ratio": ["16:9"]],
                               limits: ["references": .object(limits)], defaults: ["resolution": "2K"])
    if let operation { model.metadata["operation"] = .string(operation) }
    return model
}

let fitFormats: JSONValue = ["image/jpeg", "image/png", "image/webp"]
let fitNano = fitRecord("nano2", title: "Nano Banana 2", ["max_images": 14, "max_total_files": 14, "max_image_bytes": 31_457_280, "image_mime_types": fitFormats])
let fitSeedream = fitRecord("seedream5-flash", title: "Seedream 5.0 Flash", [
    "max_images": 10, "max_total_files": 10, "max_image_bytes": 30_000_000, "image_mime_types": fitFormats, "max_image_pixels": 36_000_000,
    "image_dimensions": ["min_side": 15], "min_image_aspect_ratio": 0.0625, "max_image_aspect_ratio": 16])

/// A measured image (no file is read by the pure checks).
func fitImage(_ width: Double, _ height: Double, name: String = "photo.jpg", bytes: Double = 1_000_000, type: String = "image/jpeg",
              alpha: Bool = false, frames: Int = 1) -> SkyStudioReference {
    var image = SkyStudioReference(type: "image", file: URL(fileURLWithPath: "/tmp/fit/\(name)"), role: "reference_image", bytes: bytes)
    image.width = width
    image.height = height
    image.contentType = type
    image.hasTransparency = alpha
    image.imageCount = frames
    return image
}

func runReferenceFitChecks() {
    // Which limits apply.
    let older = fitRecord("nano2", title: "Nano Banana 2", ["max_images": 14, "max_total_files": 14, "max_image_bytes": 31_457_280, "image_mime_types": fitFormats], fit: false)
    check(SkyStudioReferenceFit(model: older, mode: "images") == nil, "an older Sky Studio (no fit_images): nothing is fitted, uploads stay as before")
    check(SkyStudioReferenceFit.strictest([older], mode: "images") == nil, "a chain without fit_images has no target")
    guard let both = SkyStudioReferenceFit.strictest([fitNano, fitSeedream], mode: "images"),
          let nano = SkyStudioReferenceFit(model: fitNano, mode: "images") else { return check(false, "fit_images records give a target") }
    checkEqual(nano.maxBytes, 31_457_280, "one model: its own byte limit, read from the record")
    checkEqual(nano.maxPixels, nil, "one model: no pixel limit where the record has none")
    checkEqual(both.maxBytes, 30_000_000, "the chain takes the smaller byte limit")
    checkEqual(both.maxPixels, 36_000_000, "and the pixel limit only one model has")
    checkEqual(both.minSide, 15, "and the minimum side")
    checkEqual(both.minAspect, 0.0625, "and the aspect range")
    checkEqual(both.maxAspect, 16, "and the aspect range's top")
    checkEqual(both.mimeTypes, ["image/jpeg", "image/png", "image/webp"], "formats every model takes")
    checkEqual(both.modelTitles, ["Nano Banana 2", "Seedream 5.0 Flash"], "the models merged, for messages")
    let narrow = fitRecord("x", title: "X", ["max_images": 1, "max_image_bytes": 1_000, "image_mime_types": ["image/png"]])
    checkEqual(SkyStudioReferenceFit.strictest([fitNano, narrow], mode: "images")?.mimeTypes, ["image/png"], "formats are intersected")
    check(both.json != nano.json, "different limits are different identities (a prepared upload is not reused across them)")

    // At, above and below each limit.
    checkEqual(both.decide(fitImage(6000, 6000, bytes: 30_000_000)), .asIs, "exactly 30,000,000 bytes and 36,000,000 pixels: untouched")
    if case .fit(let plan) = both.decide(fitImage(6000, 6000, bytes: 30_000_001)) {
        checkEqual(plan.scale, 1, "one byte over: re-encoded at full size first")
        checkEqual(plan.contentType, "image/jpeg", "a JPEG stays JPEG")
        checkEqual(plan.reasons, ["over 30,000,000 bytes"], "the reason names the limit")
    } else { check(false, "one byte over the limit is fitted") }
    if case .fit(let plan) = both.decide(fitImage(6000, 6001)) {
        check(plan.scale < 1 && 6000 * 6001 * plan.scale * plan.scale <= 36_000_000.5, "one row over 36,000,000 pixels: scaled just under (\(plan.scale))")
    } else { check(false, "one row over the pixel limit is fitted") }
    checkEqual(nano.decide(fitImage(12_000, 9_000, bytes: 20_000_000)), .asIs, "Nano Banana 2 alone has no pixel limit: a 108 MP image under 30 MiB goes as it is")
    if case .fit(let plan) = both.decide(fitImage(4032, 3024, name: "photo.heic", type: "image/heic")) {
        checkEqual(plan.contentType, "image/jpeg", "HEIC (not taken) becomes JPEG")
        checkEqual(plan.scale, 1, "converted, never upscaled or shrunk without a reason")
    } else { check(false, "a format no model takes is converted") }
    if case .fit(let plan) = both.decide(fitImage(800, 600, name: "logo.tiff", type: "image/tiff", alpha: true)) {
        checkEqual(plan.contentType, "image/png", "a transparent TIFF becomes PNG (alpha kept)")
    } else { check(false, "a transparent TIFF is converted") }
    if case .fit(let plan) = both.decide(fitImage(9000, 9000, name: "cutout.png", bytes: 50_000_000, type: "image/png", alpha: true)) {
        checkEqual(plan.contentType, "image/png", "a PNG stays PNG when the models take PNG")
    } else { check(false, "an oversize PNG is fitted") }
    if case .fit(let plan) = both.decide(fitImage(9000, 9000, name: "screen.png", bytes: 50_000_000, type: "image/png")) {
        checkEqual(plan.contentType, "image/png", "an opaque PNG stays PNG too: only shrunk, not turned into JPEG")
    } else { check(false, "an oversize opaque PNG is fitted") }
    if case .fit(let plan) = both.decide(fitImage(4032, 3024, name: "burst.heic", type: "image/heic", frames: 2)) {
        checkEqual(plan.contentType, "image/jpeg", "a HEIC holding two images: its first image is converted")
    } else { check(false, "a multi-image HEIC is not an animation") }
    checkEqual(both.decide(fitImage(800, 600, name: "loop.webp", bytes: 900_000, type: "image/webp", frames: 12)), .asIs,
               "an animated WebP within every limit goes as it is (as before)")
    if case .refuse(let message) = both.decide(fitImage(800, 600, name: "loop.gif", type: "image/gif", frames: 12)) {
        check(message.contains("animated") && message.contains("one still image"), "an animated GIF that would need converting is refused: \(message)")
    } else { check(false, "an animated GIF is not turned into a still behind the user's back") }
    checkEqual(both.decide(fitImage(16_000, 1_000)), .asIs, "aspect exactly 16: taken")
    if case .refuse(let message) = both.decide(fitImage(16_100, 1_000)) {
        check(message.contains("too wide") && message.contains("at most 16") && message.contains("does not crop"), "aspect over 16 is refused with the limit: \(message)")
    } else { check(false, "an aspect beyond the range cannot be fitted") }
    if case .refuse(let message) = both.decide(fitImage(1_000, 16_100)) {
        check(message.contains("too tall") && message.contains("at least 0.0625"), "aspect under 1/16 is refused with the limit: \(message)")
    } else { check(false, "a tall aspect beyond the range cannot be fitted") }
    checkEqual(both.decide(fitImage(15, 15, bytes: 900)), .asIs, "15 px sides: taken")
    if case .refuse(let message) = both.decide(fitImage(14, 20, bytes: 900)) {
        check(message.contains("too small") && message.contains("at least 15 px") && message.contains("never upscales"), "a 14 px side is refused with the limit: \(message)")
    } else { check(false, "SkyCut never upscales a small image") }

    // The reference check: a fit_images model takes what SkyCut can fit; an older record still refuses.
    let big = SkyStudioReferencePlan(mode: "images", files: [fitImage(9000, 9000, bytes: 45_000_000)])
    check(big.problem(model: fitSeedream) == nil, "an image over Seedream's limits is not a reason to skip the model: it is fitted")
    check(big.problem(model: older) != nil, "without fit_images the old refusal stands (upload as before)")
    let heic = SkyStudioReferencePlan(mode: "images", files: [fitImage(4032, 3024, name: "photo.heic", type: "image/heic")])
    check(heic.problem(model: fitNano) == nil, "a HEIC photo is taken by a fit_images model")
    check(heic.problem(model: older)?.contains("accepted: image/jpeg, image/png, image/webp") == true, "an older record's format refusal names the formats it takes")
    let tiny = SkyStudioReferencePlan(mode: "images", files: [fitImage(10, 10, bytes: 500)])
    check(tiny.problem(model: fitSeedream)?.contains("at least 15 px") == true, "too small is still refused, with the limit")
    let fifteen = SkyStudioReferencePlan(mode: "images", files: (1...15).map { fitImage(1000, 1000, name: "ref\($0).jpg") })
    check(fifteen.problem(model: fitNano)?.contains("at most 14") == true, "too many images is still refused, with the count")

    // The chain: the chosen model and the defaults after it that take the same request; a named model has no fallbacks.
    let camera = fitRecord("qwen-angles", title: "Qwen Angles", ["max_images": 1, "max_image_bytes": 31_457_280, "image_mime_types": fitFormats], operation: "camera_angle")
    let catalog = SkyStudioCatalog(models: [fitSeedream, fitNano, camera])
    checkEqual(SkyStudioModelPolicy.chain(catalog: catalog, kind: "image", requested: nil, chosen: fitNano).map(\.id), ["nano2", "seedream5-flash"],
               "no model named: Nano Banana 2 and its fallback Seedream")
    checkEqual(SkyStudioModelPolicy.chain(catalog: catalog, kind: "image", requested: nil, imageContext: "asian", chosen: fitSeedream).map(\.id),
               ["seedream5-flash", "nano2"], "Asian subjects: Seedream first, Nano Banana 2 after it")
    checkEqual(SkyStudioModelPolicy.chain(catalog: catalog, kind: "image", requested: "nano2", chosen: fitNano).map(\.id), ["nano2"], "a named model has no fallbacks")
    checkEqual(SkyStudioModelPolicy.chain(catalog: catalog, kind: "image", requested: nil, chosen: camera).map(\.id), ["qwen-angles"], "an image operation has no fallbacks")
    let twelve = SkyStudioReferencePlan(mode: "images", files: (1...12).map { fitImage(1000, 1000, name: "ref\($0).jpg") })
    checkEqual(SkyStudioModelPolicy.chain(catalog: catalog, kind: "image", requested: nil, chosen: fitNano,
                                          accepts: { twelve.problem(model: $0) == nil }).map(\.id), ["nano2"],
               "a fallback that cannot take the request (12 images, Seedream takes 10) is not in the chain")

    // Sky Studio's own image records (PR #262's buildSkycutModelCatalog, checks/SkyStudio/Fixtures/models-reference-images-2026-11-23.json).
    let fixture = URL(fileURLWithPath: "checks/SkyStudio/Fixtures/models-reference-images-2026-11-23.json")
    if let data = try? Data(contentsOf: fixture), let json = try? JSONValue.decode(data), let published = SkyStudioCatalog(json: json) {
        for id in ["nano2", "nano2-lite", "nano-banana-pro", "gpt-image-2", "seedream5-flash", "seedream5-pro", "qwen-angles", "ideogram-remove-background"] {
            check(published.model(id, kind: "image").flatMap { SkyStudioReferenceFit(model: $0, mode: "images") } != nil, "\(id)'s record lets SkyCut fit images")
        }
        check(published.model("image-upscale", kind: "image").flatMap { SkyStudioReferenceFit(model: $0, mode: "images") } == nil,
              "image upscale's record does not: a source to enlarge is never shrunk")
        let removal = published.model("ideogram-remove-background", kind: "image").flatMap { SkyStudioReferenceFit(model: $0, mode: "images") }
        checkEqual(removal?.maxBytes, 10_000_000, "background removal's flat limits are read (decimal 10 MB)")
        if let nano2 = published.model("nano2", kind: "image") {
            let chain = SkyStudioModelPolicy.chain(catalog: published, kind: "image", requested: nil, chosen: nano2)
            checkEqual(chain.map(\.id), ["nano2", "seedream5-flash"], "the published catalog's default chain")
            let target = SkyStudioReferenceFit.strictest(chain, mode: "images")
            checkEqual(target?.maxBytes, 30_000_000, "fitted to Seedream's published 30,000,000 bytes")
            checkEqual(target?.maxPixels, 36_000_000, "and its 36,000,000 pixels")
            checkEqual(SkyStudioReferenceFit.strictest([nano2], mode: "images")?.maxBytes, 31_457_280, "Nano Banana 2 named alone: its 30 MiB")
        } else { check(false, "the published catalog lists nano2") }
    } else { check(false, "Sky Studio's 2026-11-23 image records load") }

    // What the AI is told.
    var planned = big
    planned.fit = both
    let notes = SkyStudioReferenceFit.notes(planned)
    checkEqual(notes.count, 1, "one note per fitted image")
    check(notes.first?.contains("over 36,000,000 pixels") == true && notes.first?.contains("the original file is unchanged") == true,
          "the note says why and that the original stays: \(notes)")
    checkEqual(SkyStudioReferenceFit.notes(SkyStudioReferencePlan(mode: "images", files: [fitImage(100, 100)])), [], "nothing fitted: no note")
}

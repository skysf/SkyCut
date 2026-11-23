import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SrtFlowMCPKit

// Reference images fitted to the published limits, the ImageIO half (docs/architecture/reference-image-fitting.md): real files
// written into a temporary folder, each just above or just below a limit (small limits keep the fixtures small; the rule is the
// same), then the copy SkyCut would upload is read back: size, format, alpha, orientation, colour profile, and the PUT to the
// fake Sky Studio carries the fitted bytes. Nothing here reads the user's files.

private struct FitFixture {
    let folder: URL

    /// A width × height picture: noise (JPEG-hostile, so bytes stay high) or a flat colour with a red top-left marker.
    func picture(_ width: Int, _ height: Int, noise: Bool = false, alpha: Bool = false, space: CFString = CGColorSpace.sRGB) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: space)!, bitmapInfo: info)!
        if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt32 = 12_345
            for index in 0 ..< context.bytesPerRow * height {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: alpha ? 0.5 : 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        }
        return context.makeImage()!
    }

    /// Writes `image` as `type`; `orientation` goes into the file's metadata (the pixels stay as stored).
    func write(_ image: CGImage, _ name: String, type: UTType, quality: Double = 1, orientation: Int? = nil) -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    func measured(_ url: URL) -> SkyStudioReference {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        return SkyStudioReferenceImage.measure(url, role: "reference_image", bytes: bytes)!
    }
}

/// Synthetic limits as a record publishes them (fit_images) — small numbers, same rules.
private func fitLimits(bytes: Double? = nil, pixels: Double? = nil, minSide: Double? = nil, formats: JSONValue = fitFormats) -> SkyStudioReferenceFit {
    var references: [String: JSONValue] = ["max_images": 4, "max_total_files": 4, "image_mime_types": formats]
    if let bytes { references["max_image_bytes"] = .number(bytes) }
    if let pixels { references["max_image_pixels"] = .number(pixels) }
    if let minSide { references["image_dimensions"] = ["min_side": .number(minSide)] }
    return SkyStudioReferenceFit(model: fitRecord("model", title: "Model", references), mode: "images")!
}

private struct ReadBack {
    var width: Int, height: Int, type: String?, alpha: Bool, space: String?, orientation: Int, topLeftRed: Bool, topRightRed: Bool
}

private func readBack(_ url: URL) -> ReadBack? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    /// Whether the image's top-left (or top-right) pixel is red: drawn into a 1×1 context (Core Graphics' origin is bottom-left).
    func red(right: Bool) -> Bool {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: right ? -image.width + 1 : 0, y: -image.height + 1, width: image.width, height: image.height))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        return pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
    }
    let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
    return ReadBack(width: image.width, height: image.height, type: type, alpha: (properties[kCGImagePropertyHasAlpha] as? Bool) == true,
                    space: image.colorSpace?.name as String?, orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
                    topLeftRed: red(right: false), topRightRed: red(right: true))
}

func runReferenceImageFitChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-reference-fit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = FitFixture(folder: folder)
    let output = folder.appendingPathComponent("out", isDirectory: true)

    // Bytes: a noisy JPEG just over / at its byte limit.
    let noisy = fixture.write(fixture.picture(900, 600, noise: true), "noisy.jpg", type: .jpeg)
    let noisyImage = fixture.measured(noisy)
    let atLimit = try? await SkyStudioReferenceImageFit.prepare(noisyImage, fit: fitLimits(bytes: noisyImage.bytes), folder: output)
    checkEqual(atLimit?.url, noisy, "a JPEG exactly at the byte limit is uploaded as it is (the original file)")
    checkEqual(atLimit?.temporary, false, "and nothing temporary is made")
    let target = (noisyImage.bytes * 0.5).rounded()
    if let sent = try? await SkyStudioReferenceImageFit.prepare(noisyImage, fit: fitLimits(bytes: target), folder: output), let back = readBack(sent.url) {
        check(sent.temporary && sent.url != noisy, "a JPEG over the byte limit goes up as a fitted copy")
        check(Double(sent.bytes ?? .max) <= target, "the copy is within the byte limit (\(sent.bytes ?? -1) ≤ \(Int(target)))")
        checkEqual(back.type, "image/jpeg", "a JPEG stays JPEG")
        check(back.width <= 900 && back.height <= 600 && abs(Double(back.width) / Double(back.height) - 1.5) < 0.01, "never larger, same shape: \(back.width)×\(back.height)")
        sent.cleanUp()
        check(!FileManager.default.fileExists(atPath: sent.url.path), "the fitted copy is removed after the upload")
    } else { check(false, "a JPEG over the byte limit can be fitted") }

    // Pixels: a transparent PNG one row over / at the pixel limit stays PNG with its alpha.
    let cutout = fixture.write(fixture.picture(600, 400, alpha: true), "cutout.png", type: .png)
    let cutoutImage = fixture.measured(cutout)
    checkEqual((try? await SkyStudioReferenceImageFit.prepare(cutoutImage, fit: fitLimits(pixels: 240_000), folder: output))?.url, cutout,
               "exactly at the pixel limit: the original")
    if let sent = try? await SkyStudioReferenceImageFit.prepare(cutoutImage, fit: fitLimits(pixels: 239_999), folder: output), let back = readBack(sent.url) {
        checkEqual(back.type, "image/png", "a transparent PNG stays PNG")
        check(back.alpha, "and keeps its alpha")
        check(back.width * back.height <= 239_999 && back.width < 600, "one pixel over: shrunk just under the limit (\(back.width)×\(back.height))")
        check(abs(Double(back.width) / Double(back.height) - 1.5) < 0.01, "the shape is kept")
        sent.cleanUp()
    } else { check(false, "a PNG over the pixel limit can be fitted") }

    // Formats: a TIFF (no model takes it) is converted, never upscaled; a transparent one becomes PNG.
    let tiff = fixture.write(fixture.picture(320, 200), "scan.tiff", type: .tiff)
    if let sent = try? await SkyStudioReferenceImageFit.prepare(fixture.measured(tiff), fit: fitLimits(pixels: 50_000_000), folder: output),
       let back = readBack(sent.url) {
        checkEqual(back.type, "image/jpeg", "an opaque TIFF goes up as JPEG")
        checkEqual(sent.contentType, "image/jpeg", "with its upload type")
        checkEqual(back.width, 320, "converted at its own size: never upscaled to the (huge) limit")
        checkEqual(back.height, 200, "height too")
        sent.cleanUp()
    } else { check(false, "a TIFF is converted") }
    let clearTiff = fixture.write(fixture.picture(320, 200, alpha: true), "clear.tiff", type: .tiff)
    if let sent = try? await SkyStudioReferenceImageFit.prepare(fixture.measured(clearTiff), fit: fitLimits(), folder: output) {
        checkEqual(readBack(sent.url)?.type, "image/png", "a transparent TIFF goes up as PNG")
        checkEqual(readBack(sent.url)?.alpha, true, "with its alpha")
        sent.cleanUp()
    } else { check(false, "a transparent TIFF is converted") }

    // Orientation: a photo stored landscape with EXIF orientation 6 (turned 90°) comes out upright, marker and all.
    let turned = fixture.write(fixture.picture(300, 200), "turned.jpg", type: .jpeg, quality: 0.9, orientation: 6)
    let turnedImage = fixture.measured(turned)
    checkEqual(turnedImage.width, 200, "measured upright")
    if let sent = try? await SkyStudioReferenceImageFit.prepare(turnedImage, fit: fitLimits(pixels: 30_000), folder: output), let back = readBack(sent.url) {
        check(back.height > back.width, "the copy is upright: portrait (\(back.width)×\(back.height))")
        checkEqual(back.orientation, 1, "with the orientation applied, not left as a tag")
        check(back.width * back.height <= 30_000, "and within the pixel limit")
        check(back.topRightRed && !back.topLeftRed, "the stored top-left marker is now top-right, where orientation 6 puts it (turned, not mirrored)")
        sent.cleanUp()
    } else { check(false, "a turned photo is fitted") }

    // Colour: a Display P3 picture keeps its profile.
    let wide = fixture.write(fixture.picture(400, 300, space: CGColorSpace.displayP3), "wide.png", type: .png)
    if let sent = try? await SkyStudioReferenceImageFit.prepare(fixture.measured(wide), fit: fitLimits(pixels: 60_000), folder: output) {
        checkEqual(readBack(sent.url)?.space, CGColorSpace.displayP3 as String, "the colour profile is kept (Display P3)")
        sent.cleanUp()
    } else { check(false, "a P3 picture is fitted") }

    // Refusals keep the limit in their words; audio, video and documents are never touched.
    let small = fixture.write(fixture.picture(12, 40), "small.png", type: .png)
    do {
        _ = try await SkyStudioReferenceImageFit.prepare(fixture.measured(small), fit: fitLimits(minSide: 15), folder: output)
        check(false, "an image below the minimum side is refused")
    } catch let failure as SkyStudioReferenceFitFailure {
        check(failure.message.contains("at least 15 px"), "the refusal names the limit: \(failure.message)")
        check(failure.reason == .tooSmall(minSide: 15, width: 12, height: 40), "and carries it for the user's words (the task row)")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }
    do {
        _ = try await SkyStudioReferenceImageFit.prepare(noisyImage, fit: fitLimits(bytes: 2_000, minSide: 300), folder: output)
        check(false, "a byte limit only reachable below the minimum side is refused, not met by breaking the other limit")
    } catch let failure as SkyStudioReferenceFitFailure {
        check(failure.message.contains("2,000 bytes") && failure.message.contains("300 px"), "it says both limits: \(failure.message)")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }

    // A 16:1 picture over only its byte limit keeps exactly 16:1 and as much of its size as fits (within the 1 % search),
    // not a step below it (Codex review of #550: 12,720 × 795 became 12,084 × 755 = 16.0053:1 and was refused).
    let banner = fixture.write(fixture.picture(1600, 100, noise: true), "banner.png", type: .png)
    let bannerImage = fixture.measured(banner)
    var aspectLimits = fitLimits(bytes: (bannerImage.bytes * 0.85).rounded())
    aspectLimits.minAspect = 0.0625
    aspectLimits.maxAspect = 16
    if let sent = try? await SkyStudioReferenceImageFit.prepare(bannerImage, fit: aspectLimits, folder: output), let back = readBack(sent.url) {
        check(Double(back.width) / Double(back.height) <= 16 && Double(back.width) / Double(back.height) >= 15.9, "the copy stays at 16:1 (\(back.width)×\(back.height))")
        check(Double(sent.bytes ?? .max) <= (bannerImage.bytes * 0.85).rounded(), "within the byte limit")
        check(back.width >= 1456, "as large as fits: a 15 % byte cut costs about 8 % of the width, not more (\(back.width) px)")
        sent.cleanUp()
    } else { check(false, "a 16:1 PNG over its byte limit is fitted") }

    // The file is measured again at upload time: rewritten after the quote, it is judged as it is now.
    let rewritten = fixture.write(fixture.picture(40, 30), "rewritten.png", type: .png)
    let stale = fixture.measured(rewritten)
    _ = fixture.write(fixture.picture(900, 600, noise: true), "rewritten.png", type: .png)
    if let sent = try? await SkyStudioReferenceImageFit.prepare(stale, fit: fitLimits(bytes: 200_000), folder: output) {
        check(sent.temporary && (sent.bytes ?? .max) <= 200_000, "a reference rewritten bigger after it was measured is fitted, not sent as it was measured")
        sent.cleanUp()
    } else { check(false, "a rewritten reference is fitted") }
    try? Data("not an image".utf8).write(to: rewritten)
    do {
        _ = try await SkyStudioReferenceImageFit.prepare(stale, fit: fitLimits(bytes: 200_000), folder: output)
        check(false, "a reference rewritten into something else is refused")
    } catch let failure as SkyStudioReferenceFitFailure {
        checkEqual(failure.reason, .unreadable, "it is refused as no longer readable")
    } catch { check(false, "a refusal is a SkyStudioReferenceFitFailure: \(error)") }
    var audio = SkyStudioReference(type: "audio", file: noisy, role: "reference_audio", bytes: 50_000_000)
    audio.contentType = "audio/wav"
    checkEqual((try? await SkyStudioReferenceImageFit.prepare(audio, fit: fitLimits(bytes: 10), folder: output))?.url, noisy, "only images are fitted")
    checkEqual((try? await SkyStudioReferenceImageFit.prepare(noisyImage, fit: nil, folder: output))?.url, noisy, "no limits (older Sky Studio): the original")

    // The upload carries the fitted bytes and type (the call SkyStudioReferenceFiles.upload makes for every reference).
    let api = SkyStudioAPI(session: SkyStudioStub.session)
    SkyStudioStub.reset { seen in
        seen.url.hasSuffix("/uploads")
            ? .http(200, #"{"upload_url": "http://127.0.0.1:8124/r2/up", "method": "PUT", "headers": {"Content-Type": "image/jpeg"}, "file_url": "https://r2.example/originals/u/skycut/up.jpg"}"#)
            : .http(200, "")
    }
    if let sent = try? await SkyStudioReferenceImageFit.prepare(fixture.measured(tiff), fit: fitLimits(), folder: output), let type = sent.contentType {
        _ = try? await api.upload(fileURL: sent.url, contentType: type, purpose: "image", key: "sk-" + String(repeating: "f", count: 43)) { _ in }
        let ask = SkyStudioStub.log.first.flatMap { $0.body }.flatMap { try? JSONValue.decode($0) }
        checkEqual(ask?["content_type"]?.stringValue, "image/jpeg", "/uploads is asked for the fitted type")
        checkEqual(SkyStudioStub.log.last?.body, try? Data(contentsOf: sent.url), "the PUT carries the fitted copy's bytes")
        sent.cleanUp()
    } else { check(false, "the fitted copy can be uploaded") }
}

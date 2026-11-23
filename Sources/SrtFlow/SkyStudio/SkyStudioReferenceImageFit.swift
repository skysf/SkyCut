import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - The file a reference image is uploaded as: the original, or a copy fitted to the limits (ImageIO / Core Graphics)
// What it does: measures the file again at upload time (it may have been rewritten since the quote), asks SkyStudioReferenceFit
// what to do with it and, when it must be fitted, writes a copy with the EXIF orientation applied and the colour profile kept,
// in the format the plan names (JPEG / PNG), at an exact integer size that meets every pixel limit and keeps the final aspect
// inside the published range, and as large as the byte limit allows (JPEG first gives up a little quality, never below 0.8;
// then the largest size that fits is searched to within 1 %). Never upscaled. The copy has no other metadata (no GPS) and goes
// into a temporary folder; the caller removes it after the upload. Decoding and encoding run on MediaReadQueue.analysis,
// never on the cooperative pool (docs/architecture/blocking-media-reads.md).
// Not here: the decision (SkyStudioReferenceFit), the upload itself (SkyStudioReferenceFiles → SkyStudioAPI.upload).
// Rules: docs/architecture/reference-image-fitting.md.

enum SkyStudioReferenceImageFit {
    /// What goes up for one reference. `temporary`: a fitted copy, removed after the upload.
    struct Upload: Equatable, Sendable {
        var url: URL
        var contentType: String?
        var temporary: Bool
        var width: Int? = nil
        var height: Int? = nil
        var bytes: Int? = nil

        func cleanUp() {
            if temporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Where fitted copies are written.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SkyCutReferenceFit", isDirectory: true) }

    /// The file to upload for one measured reference. Without limits (an older Sky Studio), or for audio, video and documents,
    /// it is the original; a refusal throws SkyStudioReferenceFitFailure, which names the limit.
    static func prepare(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> Upload {
        guard let fit, file.type == "image" else { return Upload(url: file.file, contentType: file.contentType, temporary: false) }
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try prepareNow(file, fit: fit, folder: folder) }
        }.get()
    }

    /// The blocking half of `prepare`: measure again, decide, write.
    static func prepareNow(_ planned: SkyStudioReference, fit: SkyStudioReferenceFit, folder: URL) throws -> Upload {
        // The plan was measured before the quote; the same path may hold other bytes now.
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: planned.file.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        guard bytes > 0, let file = SkyStudioReferenceImage.measure(planned.file, role: planned.role, bytes: bytes) else {
            throw SkyStudioReferenceFitFailure(file: planned.file.lastPathComponent, models: fit.modelTitles, reason: .unreadable)
        }
        switch fit.decide(file) {
        case .asIs: return Upload(url: file.file, contentType: file.contentType, temporary: false)
        case .refuse(let failure): throw failure
        case .fit(let plan): return try write(file, plan: plan, fit: fit, folder: folder)
        }
    }

    /// Writes the fitted copy. Synchronous and blocking: only through `prepare` (or a check).
    static func write(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit, folder: URL) throws -> Upload {
        let failed = { (detail: String) in
            SkyStudioReferenceFitFailure(file: file.file.lastPathComponent, models: fit.modelTitles, reason: .cannotFit(detail: detail))
        }
        guard let width = file.width, let height = file.height,
              let source = CGImageSourceCreateWithURL(file.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let largest = fit.size(width: width, height: height, scale: plan.scale),
              let base = upright(source, edge: max(largest.width, largest.height)) else { throw failed("it could not be decoded") }
        let png = plan.contentType == "image/png"
        let flatten = !png && file.hasTransparency
        /// The copy at `scale`, encoded; nil when its size would break the limits (a side below the minimum).
        func encoded(_ scale: Double, quality: Double) throws -> (data: Data, width: Int, height: Int)? {
            guard let size = fit.size(width: width, height: height, scale: scale) else { return nil }
            guard let image = sized(base, width: size.width, height: size.height) else { throw failed("it could not be resized") }
            return (try encode(image, png: png, quality: quality, flatten: flatten, failed: failed), size.width, size.height)
        }
        let fits = { (data: Data) in fit.maxBytes.map { Double(data.count) <= $0 } ?? true }
        var quality = 0.92
        guard var best = try encoded(plan.scale, quality: quality) else { throw failed("the pixel limits would take a side below the minimum") }
        while !fits(best.data), !png, quality > 0.81, let next = try encoded(plan.scale, quality: quality - 0.06) {
            quality -= 0.06
            best = next
        }
        if !fits(best.data), let maxBytes = fit.maxBytes {
            guard let fitting = try SkyStudioReferenceFit.largestFitting(below: plan.scale, firstBytes: best.data.count, maxBytes: maxBytes,
                                                                          bytesOf: { $0.data.count }, encode: { try encoded($0, quality: quality) }) else {
                throw failed("only a side below \(SkyStudioReferenceFit.text(fit.minSide ?? 1)) px would come under \(SkyStudioReferenceFit.text(maxBytes)) bytes")
            }
            best = fitting
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
        try best.data.write(to: output, options: .atomic)
        return Upload(url: output, contentType: plan.contentType, temporary: true, width: best.width, height: best.height, bytes: best.data.count)
    }

    /// The picture upright (EXIF orientation applied) with its long side at most `edge` (never larger than the original).
    private static func upright(_ source: CGImageSource, edge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, edge)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image` drawn at exactly width × height in its own colour space (no conversion; CMYK and other spaces go to sRGB).
    private static func sized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        let alpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let gray = space.model == .monochrome && !alpha
        if space.model != .rgb && !gray { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = gray ? CGImageAlphaInfo.none.rawValue : (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, png: Bool, quality: Double, flatten: Bool,
                               failed: (String) -> SkyStudioReferenceFitFailure) throws -> Data {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw failed("it could not be written") }
        let properties: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, flatten ? flattened(image) : image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failed("it could not be written") }
        return data as Data
    }

    /// A transparent image that must become JPEG goes onto white (JPEG has no alpha), in its own RGB colour space.
    private static func flattened(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(frame)
        context.draw(image, in: frame)
        return context.makeImage() ?? image
    }
}

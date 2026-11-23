import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - The file a reference image is uploaded as: the original, or a copy fitted to the limits (ImageIO / Core Graphics)
// What it does: asks SkyStudioReferenceFit what to do with one image and, when it must be fitted, writes a copy with the EXIF
// orientation applied and the colour profile kept, in the format the plan names (JPEG / PNG), downscaled only as far as the
// pixel limits need and then the byte limit needs (JPEG first gives up a little quality, never below 0.8); never upscaled.
// The copy has no other metadata (no GPS) and goes into a temporary folder; the caller removes it after the upload.
// The decoding runs on MediaReadQueue.analysis, never on the cooperative pool (docs/architecture/blocking-media-reads.md).
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
    /// it is the original; a refusal throws its message, which names the limit.
    static func prepare(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> Upload {
        let original = Upload(url: file.file, contentType: file.contentType, temporary: false)
        guard let fit, file.type == "image" else { return original }
        switch fit.decide(file) {
        case .asIs:
            return original
        case .refuse(let message):
            throw AIToolError(message)
        case .fit(let plan):
            return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                Result { try write(file, plan: plan, fit: fit, folder: folder) }
            }.get()
        }
    }

    /// Writes the fitted copy. Synchronous and blocking: only through `prepare` (or a check).
    static func write(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit, folder: URL) throws -> Upload {
        let name = file.file.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(file.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let width = file.width, let height = file.height else { throw AIToolError("SkyCut could not read \(name) to fit it.") }
        let png = plan.contentType == "image/png"
        let longSide = max(width, height)
        var scale = min(plan.scale, 1)
        var quality = 0.92
        for _ in 0 ..< 12 {
            let image = try oriented(source, edge: Int((longSide * scale).rounded(.down)), fit: fit, name: name)
            if let minSide = fit.minSide, Double(min(image.width, image.height)) < minSide {
                throw AIToolError("\(name) cannot be fitted under \(SkyStudioReferenceFit.text(fit.maxBytes ?? 0)) bytes for "
                    + "\(fit.modelTitles.joined(separator: " / ")) without a side below \(SkyStudioReferenceFit.text(minSide)) px.")
            }
            let data = try encode(image, png: png, quality: quality, flatten: !png && file.hasTransparency)
            guard let maxBytes = fit.maxBytes, Double(data.count) > maxBytes else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
                try data.write(to: output, options: .atomic)
                return Upload(url: output, contentType: plan.contentType, temporary: true, width: image.width, height: image.height, bytes: data.count)
            }
            if !png && quality > 0.81 {
                quality -= 0.06
            } else {
                scale *= min(0.95, (maxBytes / Double(data.count)).squareRoot() * 0.97)
            }
        }
        throw AIToolError("SkyCut could not fit \(name) under \(SkyStudioReferenceFit.text(fit.maxBytes ?? 0)) bytes for \(fit.modelTitles.joined(separator: " / ")).")
    }

    /// The image upright (EXIF orientation applied) with its long side at most `edge`, then nudged down until it meets the pixel
    /// limits (the short side is rounded by ImageIO). Never larger than the original.
    private static func oriented(_ source: CGImageSource, edge: Int, fit: SkyStudioReferenceFit, name: String) throws -> CGImage {
        var edge = max(1, edge)
        for _ in 0 ..< 6 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw AIToolError("SkyCut could not decode \(name) to fit it.")
            }
            let pixels = Double(image.width * image.height)
            let tooMany = fit.maxPixels.map { pixels > $0 } ?? false
            let tooLong = fit.maxSide.map { Double(max(image.width, image.height)) > $0 } ?? false
            if !tooMany && !tooLong { return image }
            edge = max(1, min(edge, max(image.width, image.height)) - max(1, edge / 1000))
        }
        throw AIToolError("SkyCut could not bring \(name) within the pixel limits.")
    }

    private static func encode(_ image: CGImage, png: Bool, quality: Double, flatten: Bool) throws -> Data {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw AIToolError("SkyCut could not write the fitted image.") }
        let properties: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, flatten ? flattened(image) : image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIToolError("SkyCut could not write the fitted image.") }
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

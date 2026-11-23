import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - The file a reference image is uploaded as: the original, or a copy fitted to the limits (ImageIO / Core Graphics)
// What it does: measures the file again at upload time (it may have been rewritten since the quote), asks SkyStudioReferenceFit
// what to do with it and, when it must be fitted, writes a copy with the EXIF orientation applied and the colour profile kept,
// in the format the plan names (JPEG / PNG), at an exact integer size that meets every pixel limit and keeps the final aspect
// inside the published range, and as large as the byte limit allows (JPEG first gives up a little quality, never below 0.8;
// then the largest size that fits is searched to within 1 %). Never upscaled. For a request's whole set it then shares a total
// for all reference images together (SkyStudioReferenceTotal): the largest are written again from their originals, smaller
// still, never below SkyCut's floor. The copy has no other metadata (no GPS) and goes into a temporary folder; the caller
// removes it after the upload. Decoding and encoding run on MediaReadQueue.analysis, never on the cooperative pool
// (docs/architecture/blocking-media-reads.md).
// Not here: the decisions (SkyStudioReferenceFit, SkyStudioReferenceTotal), the upload itself (SkyStudioReferenceFiles →
// SkyStudioAPI.upload).
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

    /// One reference as measured at upload time, and what goes up for it.
    struct Prepared: Sendable {
        var file: SkyStudioReference
        var upload: Upload
    }

    /// An encoded copy of an image.
    struct Copy: Sendable {
        var data: Data
        var width: Int
        var height: Int
    }

    /// JPEG qualities tried at the plan's size before the size itself comes down: a little quality first, never below the last.
    static let qualities = [0.92, 0.86, 0.8]

    /// Where fitted copies are written.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SkyCutReferenceFit", isDirectory: true) }

    /// The files to upload for a request's references, in order. Each image is fitted to its own limits; when the models also
    /// publish a total for all reference images together and the set is over it, the largest are made smaller still
    /// (`shareTotal`). Throws before anything is uploaded (a refusal is a SkyStudioReferenceFitFailure that names the limit), and
    /// then removes every copy it made.
    static func prepare(_ files: [SkyStudioReference], fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> [Upload] {
        var prepared: [Prepared] = []
        do {
            for file in files {
                try Task.checkCancellation()
                prepared.append(try await measured(file, fit: fit, folder: folder))
            }
            guard let fit, let total = fit.maxTotalBytes else { return prepared.map(\.upload) }
            try Task.checkCancellation()
            let each = prepared
            return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                Result { try shareTotal(each, fit: fit, total: total, folder: folder) }
            }.get()
        } catch {
            prepared.forEach { $0.upload.cleanUp() }
            throw error
        }
    }

    /// The file to upload for one measured reference, against its own limits only (a set goes through `prepare(_:fit:folder:)`
    /// with its files). Without limits (an older Sky Studio), or for audio, video and documents, it is the original; a refusal
    /// throws SkyStudioReferenceFitFailure, which names the limit.
    static func prepare(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> Upload {
        try await measured(file, fit: fit, folder: folder).upload
    }

    private static func measured(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL) async throws -> Prepared {
        guard let fit, file.type == "image" else {
            return Prepared(file: file, upload: Upload(url: file.file, contentType: file.contentType, temporary: false))
        }
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try prepareNow(file, fit: fit, folder: folder) }
        }.get()
    }

    /// The blocking half of `prepare`: measure again, decide, write.
    static func prepareNow(_ planned: SkyStudioReference, fit: SkyStudioReferenceFit, folder: URL) throws -> Prepared {
        // The plan was measured before the quote; the same path may hold other bytes now.
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: planned.file.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        guard bytes > 0, let file = SkyStudioReferenceImage.measure(planned.file, role: planned.role, bytes: bytes) else {
            throw SkyStudioReferenceFitFailure(file: planned.file.lastPathComponent, models: fit.modelTitles, reason: .unreadable)
        }
        switch fit.decide(file) {
        case .asIs: return Prepared(file: file, upload: Upload(url: file.file, contentType: file.contentType, temporary: false, bytes: Int(bytes)))
        case .refuse(let failure): throw failure
        case .fit(let plan): return Prepared(file: file, upload: try write(file, plan: plan, fit: fit, folder: folder))
        }
    }

    /// The set over a total for all its images (SkyStudioReferenceTotal.share): an image over the common cap gets a new copy from
    /// its original, as large as the cap allows; one whose smallest allowed copy is still over the cap goes up as that copy; the
    /// rest stay byte-identical. Throws (a refusal naming the total) when even the smallest copies pass it. Blocking.
    static func shareTotal(_ prepared: [Prepared], fit: SkyStudioReferenceFit, total: Double, folder: URL) throws -> [Upload] {
        let images = prepared.indices.filter { prepared[$0].file.type == "image" }
        let sizes = images.map { Double(prepared[$0].upload.bytes ?? Int(prepared[$0].file.bytes)) }
        var smallest: [Int: (copy: Copy, contentType: String)] = [:]
        let targets = try SkyStudioReferenceTotal.share(sizes, total: total) { index in
            guard let made = try smallestCopy(prepared[images[index]].file, fit: fit) else { return sizes[index] }
            smallest[index] = made
            return Double(made.copy.data.count)
        }
        guard let targets else {
            throw SkyStudioReferenceFitFailure(file: images.map { prepared[$0].file.file.lastPathComponent }.joined(separator: ", "),
                                               models: fit.modelTitles, reason: .tooLargeTogether(total: total, count: images.count))
        }
        var uploads = prepared.map(\.upload)
        var made: [Upload] = []
        do {
            for (position, target) in targets.enumerated() {
                let index = images[position], file = prepared[index].file
                // Only an image whose smallest copy could be made is ever asked to come down, so both have a copy to give.
                let stuck = SkyStudioReferenceFitFailure(file: file.file.lastPathComponent, models: fit.modelTitles,
                                                         reason: .cannotFit(detail: "it could not be made smaller"))
                let copy: Upload
                switch target {
                case .keep:
                    continue
                case .cap(let cap):
                    let capped = fit.capped(cap)
                    guard case .fit(let plan) = capped.decide(file) else { throw stuck }
                    copy = try write(file, plan: plan, fit: capped, folder: folder, lowest: floorScale(file, plan: plan, fit: fit))
                case .smallest:
                    guard let small = smallest[position] else { throw stuck }
                    copy = try save(small.copy, as: small.contentType, folder: folder)
                }
                made.append(copy)
                uploads[index].cleanUp()  // the copy fitted to its own limits that this one replaces; an original is never removed
                uploads[index] = copy
            }
        } catch {
            made.forEach { $0.cleanUp() }
            throw error
        }
        return uploads
    }

    /// The smallest copy SkyCut allows when the images share a total: at `floorScale` and, for JPEG, the last of `qualities`.
    /// Decoded as `write` decodes (at the plan's size, then resampled), so the byte search reaches exactly this copy at its floor.
    /// Nil when the image cannot be made smaller (an animation; a size the pixel limits refuse): it stays as it is.
    static func smallestCopy(_ file: SkyStudioReference, fit: SkyStudioReferenceFit) throws -> (copy: Copy, contentType: String)? {
        // Any byte cap below the image gives the same plan (format and pixel scale); 0 asks for it whatever the image's size.
        guard case .fit(let plan) = fit.capped(0).decide(file) else { return nil }
        let source = try Source(file, plan: plan, fit: fit, scale: plan.scale)
        return try source.encoded(floorScale(file, plan: plan, fit: fit), quality: qualities[qualities.count - 1]).map { ($0, plan.contentType) }
    }

    /// The smallest scale of a copy made to share a total: a long side of SkyStudioReferenceTotal.floorEdge, or the plan's own
    /// size when that is already smaller (never upscaled), and a short side over the models' minimum.
    static func floorScale(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit) -> Double {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return plan.scale }
        return min(plan.scale, max(SkyStudioReferenceTotal.floorEdge / max(width, height), ((fit.minSide ?? 0) + 1) / min(width, height)))
    }

    /// Writes the fitted copy, never below scale `lowest`. Synchronous and blocking: only through `prepare` (or a check).
    static func write(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit, folder: URL,
                      lowest: Double = 0) throws -> Upload {
        let source = try Source(file, plan: plan, fit: fit, scale: plan.scale)
        let fits = { (copy: Copy) in fit.maxBytes.map { Double(copy.data.count) <= $0 } ?? true }
        var quality = qualities[0]
        guard var best = try source.encoded(plan.scale, quality: quality) else { throw source.failed("the pixel limits would take a side below the minimum") }
        for next in qualities.dropFirst() where !fits(best) && !source.png {
            guard let copy = try source.encoded(plan.scale, quality: next) else { break }
            quality = next
            best = copy
        }
        if !fits(best), let maxBytes = fit.maxBytes {
            guard let fitting = try SkyStudioReferenceFit.largestFitting(below: plan.scale, lowest: lowest, firstBytes: best.data.count, maxBytes: maxBytes,
                                                                          bytesOf: { $0.data.count }, encode: { try source.encoded($0, quality: quality) }) else {
                let below = lowest > 0 ? "a long side below \(SkyStudioReferenceFit.text(SkyStudioReferenceTotal.floorEdge)) px"
                    : "a side below \(SkyStudioReferenceFit.text(fit.minSide ?? 1)) px"
                throw source.failed("only \(below) would come under \(SkyStudioReferenceFit.text(maxBytes)) bytes")
            }
            best = fitting
        }
        return try save(best, as: plan.contentType, folder: folder)
    }

    private static func save(_ copy: Copy, as contentType: String, folder: URL) throws -> Upload {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(UUID().uuidString + (contentType == "image/png" ? ".png" : ".jpg"))
        try copy.data.write(to: output, options: .atomic)
        return Upload(url: output, contentType: contentType, temporary: true, width: copy.width, height: copy.height, bytes: copy.data.count)
    }

    /// One image decoded once, upright, at the size of its copy at `scale`, to encode copies of it at that scale or below
    /// (resampled from this one decode, so a copy at a scale is the same whoever asks for it).
    private struct Source {
        let file: SkyStudioReference
        let fit: SkyStudioReferenceFit
        let png: Bool
        let flatten: Bool
        let base: CGImage

        init(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit, scale: Double) throws {
            self.file = file
            self.fit = fit
            png = plan.contentType == "image/png"
            flatten = !png && file.hasTransparency
            let failure = SkyStudioReferenceFitFailure(file: file.file.lastPathComponent, models: fit.modelTitles,
                                                       reason: .cannotFit(detail: "it could not be decoded"))
            guard let width = file.width, let height = file.height,
                  let source = CGImageSourceCreateWithURL(file.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let largest = fit.size(width: width, height: height, scale: scale),
                  let base = SkyStudioReferenceImageFit.upright(source, edge: max(largest.width, largest.height)) else { throw failure }
            self.base = base
        }

        func failed(_ detail: String) -> SkyStudioReferenceFitFailure {
            SkyStudioReferenceFitFailure(file: file.file.lastPathComponent, models: fit.modelTitles, reason: .cannotFit(detail: detail))
        }

        /// The copy at `scale`, encoded; nil when its size would break the limits (a side below the minimum).
        func encoded(_ scale: Double, quality: Double) throws -> Copy? {
            guard let width = file.width, let height = file.height, let size = fit.size(width: width, height: height, scale: scale) else { return nil }
            guard let image = SkyStudioReferenceImageFit.sized(base, width: size.width, height: size.height) else { throw failed("it could not be resized") }
            return Copy(data: try SkyStudioReferenceImageFit.encode(image, png: png, quality: quality, flatten: flatten, failed: failed),
                        width: size.width, height: size.height)
        }
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

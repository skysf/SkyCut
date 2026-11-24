import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - The file a reference image is uploaded as: a stable copy of the original, or a copy fitted to the limits (ImageIO)
// What it does: copies the user's file as it is now (a snapshot in a folder of its own; APFS clones it) and works only from that
// copy, so what was measured is what goes up, whatever happens to the path while the set is prepared or uploaded. It measures
// the snapshot (the plan was measured before the quote), asks SkyStudioReferenceFit what to do and, when the image must be
// fitted, writes a copy with the EXIF orientation applied and the colour profile kept, in the format the plan names (JPEG /
// PNG), at an exact integer size that meets every pixel limit and keeps the final aspect inside the published range, and as
// large as the byte limit allows (JPEG first gives up a little quality, never below 0.8; then the largest size that fits is
// searched to within 1 %). Never upscaled. For a request's whole set it then shares a total for all reference images together
// (SkyStudioReferenceTotal with SkyStudioReferenceSetImage), by real encoded sizes. Copies carry no other metadata (no GPS) and
// live in a temporary folder that the caller empties after the upload. Decoding and encoding run on MediaReadQueue.analysis,
// never on the cooperative pool (docs/architecture/blocking-media-reads.md).
// Not here: the decisions (SkyStudioReferenceFit, SkyStudioReferenceTotal), the upload itself (SkyStudioReferenceFiles →
// SkyStudioAPI.upload).
// Rules: docs/architecture/reference-image-fitting.md.

enum SkyStudioReferenceImageFit {
    /// What goes up for one reference. `temporary`: a snapshot or a fitted copy, removed after the upload.
    struct Upload: Equatable, Sendable {
        var url: URL
        var contentType: String?
        var temporary: Bool
        var width: Int? = nil
        var height: Int? = nil
        var bytes: Int? = nil
        /// The JPEG quality and the scale of a copy SkyCut wrote (nil: the user's own bytes): what full-size steps it has left.
        var quality: Double? = nil
        var scale: Double? = nil
        /// A snapshot of the user's file, alone in a folder of its own so that it keeps the file's name: the folder goes with it.
        var snapshot = false

        func cleanUp() {
            guard temporary else { return }
            try? FileManager.default.removeItem(at: snapshot ? url.deletingLastPathComponent() : url)
        }
    }

    /// One reference as measured at upload time and what goes up for it.
    struct Prepared: Sendable {
        /// Measured from the snapshot (`file.file` is the snapshot, with the user's file name).
        var file: SkyStudioReference
        var upload: Upload
        /// The stable copy the image was measured from, removed once no upload uses it. Nil for what is never fitted (audio,
        /// video, documents, an older Sky Studio): those go up from their own path, as before.
        var snapshot: Upload?
    }

    /// An encoded copy of an image, with the quality and scale it was encoded at.
    struct Copy: Sendable {
        var data: Data
        var width: Int
        var height: Int
        var quality: Double
        var scale: Double
    }

    /// JPEG qualities tried at the plan's size before the size itself comes down: a little quality first, never below the last.
    static let qualities = [0.92, 0.86, 0.8]

    /// Where snapshots and fitted copies are written.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SkyCutReferenceFit", isDirectory: true) }

    /// The files to upload for a request's references, in order. Each image is fitted to its own limits; when the models also
    /// publish a total for all reference images together and the set is over it, the set is shared (`shareTotal`). Throws
    /// before anything is uploaded (a refusal is a SkyStudioReferenceFitFailure that names the limit), and then removes every
    /// snapshot and copy it made.
    static func prepare(_ files: [SkyStudioReference], fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> [Upload] {
        var prepared: [Prepared] = []
        do {
            for file in files {
                try Task.checkCancellation()
                prepared.append(try await measured(file, fit: fit, folder: folder))
            }
            if let fit, let total = fit.maxTotalBytes {
                try Task.checkCancellation()
                let each = prepared
                prepared = try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                    Result { try shareTotal(each, fit: fit, total: total, folder: folder) }
                }.get()
            }
            // A snapshot that no upload uses (the image goes up as a copy made from it) is not needed any more.
            for item in prepared where item.snapshot.map({ $0.url != item.upload.url }) == true { item.snapshot?.cleanUp() }
            return prepared.map(\.upload)
        } catch {
            prepared.forEach { $0.upload.cleanUp(); $0.snapshot?.cleanUp() }
            throw error
        }
    }

    /// The file to upload for one reference against its own limits only (no total). Without limits (an older Sky Studio), or
    /// for audio, video and documents, it is the original; a refusal throws SkyStudioReferenceFitFailure, which names the limit.
    static func prepare(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL = folder) async throws -> Upload {
        var own = fit
        own?.maxTotalBytes = nil
        return try await prepare([file], fit: own, folder: folder)[0]
    }

    private static func measured(_ file: SkyStudioReference, fit: SkyStudioReferenceFit?, folder: URL) async throws -> Prepared {
        guard let fit, file.type == "image" else {
            return Prepared(file: file, upload: Upload(url: file.file, contentType: file.contentType, temporary: false), snapshot: nil)
        }
        return try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try prepareNow(file, fit: fit, folder: folder) }
        }.get()
    }

    /// The blocking half of `prepare`: a snapshot of the file as it is now, measured, decided and, when needed, fitted.
    static func prepareNow(_ planned: SkyStudioReference, fit: SkyStudioReferenceFit, folder: URL) throws -> Prepared {
        let unreadable = SkyStudioReferenceFitFailure(file: planned.file.lastPathComponent, models: fit.modelTitles, reason: .unreadable)
        guard var snapshot = try? snapshot(of: planned.file, folder: folder) else { throw unreadable }
        do {
            // The plan was measured before the quote; the same path may hold other bytes now, so its snapshot is measured again.
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: snapshot.url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
            guard bytes > 0, let file = SkyStudioReferenceImage.measure(snapshot.url, role: planned.role, bytes: bytes) else { throw unreadable }
            snapshot.contentType = file.contentType
            snapshot.bytes = Int(bytes)
            switch fit.decide(file) {
            case .asIs: return Prepared(file: file, upload: snapshot, snapshot: snapshot)
            case .refuse(let failure): throw failure
            case .fit(let plan): return Prepared(file: file, upload: try write(file, plan: plan, fit: fit, folder: folder), snapshot: snapshot)
            }
        } catch {
            snapshot.cleanUp()
            throw error
        }
    }

    /// A copy of the user's file as it is now, alone in a new folder under `folder`, so that it keeps the file's name (messages
    /// name the user's file). APFS clones it: no time or space spent there.
    private static func snapshot(of file: URL, folder: URL) throws -> Upload {
        let own = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let copy = own.appendingPathComponent(file.lastPathComponent)
        do { try FileManager.default.copyItem(at: file, to: copy) } catch { try? FileManager.default.removeItem(at: own); throw error }
        return Upload(url: copy, contentType: nil, temporary: true, snapshot: true)
    }

    /// The set over a total for all its images: SkyStudioReferenceTotal.share decides with real copies of each
    /// (SkyStudioReferenceSetImage), then the copies it chose are written. Throws a refusal naming the total when the set cannot
    /// be brought within it (nothing written then). Blocking.
    static func shareTotal(_ prepared: [Prepared], fit: SkyStudioReferenceFit, total: Double, folder: URL) throws -> [Prepared] {
        let images = prepared.indices.filter { prepared[$0].file.type == "image" }
        var each = images.map { SkyStudioReferenceSetImage(prepared[$0], fit: fit) }
        guard try SkyStudioReferenceTotal.share(&each, total: total) else {
            throw SkyStudioReferenceFitFailure(file: images.map { prepared[$0].file.file.lastPathComponent }.joined(separator: ", "),
                                               models: fit.modelTitles, reason: .tooLargeTogether(total: total, count: images.count))
        }
        var result = prepared
        var made: [Upload] = []
        do {
            for (position, image) in each.enumerated() {
                guard let copy = image.copy, let plan = image.plan else { continue }
                let index = images[position]
                let upload = try save(copy, as: plan.contentType, folder: folder)
                made.append(upload)
                // A copy for its own limits that this one replaces goes now; a snapshot goes when the set is done.
                if result[index].upload.url != result[index].snapshot?.url { result[index].upload.cleanUp() }
                result[index].upload = upload
            }
        } catch {
            made.forEach { $0.cleanUp() }
            throw error
        }
        return result
    }

    /// The smallest scale of a copy made to share a total: a long side of SkyStudioReferenceTotal.floorEdge (half a pixel over,
    /// so that rounding the scaled side down never lands one under), or the plan's own size when that is already smaller (never
    /// upscaled), and a short side over the models' minimum.
    static func floorScale(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit) -> Double {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return plan.scale }
        return min(plan.scale, max((SkyStudioReferenceTotal.floorEdge + 0.5) / max(width, height), ((fit.minSide ?? 0) + 1) / min(width, height)))
    }

    /// Writes the copy fitted to the image's own limits. Synchronous and blocking: only through `prepare` (or a check).
    static func write(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit, folder: URL) throws -> Upload {
        let source = try Source(file, plan: plan, fit: fit)
        let fits = { (copy: Copy) in fit.maxBytes.map { Double(copy.data.count) <= $0 } ?? true }
        var quality = qualities[0]
        guard var best = try source.encoded(plan.scale, quality: quality) else { throw source.failed("the pixel limits would take a side below the minimum") }
        for next in qualities.dropFirst() where !fits(best) && !source.png {
            guard let copy = try source.encoded(plan.scale, quality: next) else { break }
            quality = next
            best = copy
        }
        if !fits(best), let maxBytes = fit.maxBytes {
            guard let fitting = try SkyStudioReferenceFit.largestFitting(below: plan.scale, firstBytes: best.data.count, maxBytes: maxBytes,
                                                                          bytesOf: { $0.data.count }, encode: { try source.encoded($0, quality: quality) }) else {
                throw source.failed("only a side below \(SkyStudioReferenceFit.text(fit.minSide ?? 1)) px would come under \(SkyStudioReferenceFit.text(maxBytes)) bytes")
            }
            best = fitting
        }
        return try save(best, as: plan.contentType, folder: folder)
    }

    static func save(_ copy: Copy, as contentType: String, folder: URL) throws -> Upload {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(UUID().uuidString + (contentType == "image/png" ? ".png" : ".jpg"))
        try copy.data.write(to: output, options: .atomic)
        return Upload(url: output, contentType: contentType, temporary: true, width: copy.width, height: copy.height, bytes: copy.data.count,
                      quality: contentType == "image/png" ? nil : copy.quality, scale: copy.scale)
    }

    /// One image decoded once, upright, at the plan's size, to encode copies of it at that scale or below (resampled from this one
    /// decode, so a copy at a scale is the same whoever asks for it).
    struct Source {
        let file: SkyStudioReference
        let fit: SkyStudioReferenceFit
        let png: Bool
        let flatten: Bool
        let base: CGImage

        init(_ file: SkyStudioReference, plan: SkyStudioReferenceFit.Plan, fit: SkyStudioReferenceFit) throws {
            self.file = file
            self.fit = fit
            png = plan.contentType == "image/png"
            flatten = !png && file.hasTransparency
            let failure = SkyStudioReferenceFitFailure(file: file.file.lastPathComponent, models: fit.modelTitles,
                                                       reason: .cannotFit(detail: "it could not be decoded"))
            guard let width = file.width, let height = file.height,
                  let source = CGImageSourceCreateWithURL(file.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let largest = fit.size(width: width, height: height, scale: plan.scale),
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
                        width: size.width, height: size.height, quality: quality, scale: scale)
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

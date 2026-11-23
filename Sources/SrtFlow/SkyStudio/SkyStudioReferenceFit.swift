import Foundation
import SrtFlowMCPKit

// MARK: - Fitting a reference image to the models' published limits (pure values)
// What it does: reads a model's reference-image limits from /models, but only when its record says `fit_images: true`
// (`max_image_bytes`, `max_total_image_bytes`, `max_image_pixels`, `image_dimensions` / `media_dimensions` min and max side,
// the aspect range, `image_mime_types`); merges the limits of the chosen model and its fallbacks into the strictest; and decides
// for one measured image: upload it unchanged, fit it (convert, re-encode, downscale; never upscale), or refuse it with the limit.
// Not here: pixels and files (SkyStudioReferenceImageFit), sharing a total among the images (SkyStudioReferenceTotal), which
// models form the chain (SkyStudioModelPolicy.fallbacks), uploading (SkyStudioReferenceFiles). Every number comes from the
// server's catalog; none is written here.
// Rules: docs/architecture/reference-image-fitting.md.

struct SkyStudioReferenceFit: Equatable, Sendable {
    var maxBytes: Double?
    /// Every reference image of one request together; nil: no total (SkyStudioReferenceTotal shares it).
    var maxTotalBytes: Double?
    var maxPixels: Double?
    var maxSide: Double?
    var minSide: Double?
    var minAspect: Double?
    var maxAspect: Double?
    /// Formats every model of the chain takes; nil when none lists any.
    var mimeTypes: [String]?
    /// The models merged, for messages.
    var modelTitles: [String]

    enum Decision: Equatable, Sendable {
        case asIs
        case fit(Plan)
        case refuse(SkyStudioReferenceFitFailure)
    }

    /// How to fit one image: the format to write and the largest scale the pixel limits allow (at most 1).
    struct Plan: Equatable, Sendable {
        var contentType: String
        var scale: Double
        var reasons: [String]
    }

    /// The formats SkyCut can write (ImageIO writes no WebP).
    static let writable = ["image/jpeg", "image/png"]
    /// Formats that may hold an animation: several frames there are not one still image to take the first of.
    static let animated = ["image/gif", "image/png", "image/webp"]

    /// The strictest limits of the models an image may be sent to; nil when none of them allows fitting (upload as before).
    static func strictest(_ models: [SkyStudioModel], mode: String) -> SkyStudioReferenceFit? {
        let all = models.compactMap { SkyStudioReferenceFit(model: $0, mode: mode) }
        guard var result = all.first else { return nil }
        for next in all.dropFirst() {
            result.maxBytes = stricter(result.maxBytes, next.maxBytes, by: min)
            result.maxTotalBytes = stricter(result.maxTotalBytes, next.maxTotalBytes, by: min)
            result.maxPixels = stricter(result.maxPixels, next.maxPixels, by: min)
            result.maxSide = stricter(result.maxSide, next.maxSide, by: min)
            result.minSide = stricter(result.minSide, next.minSide, by: max)
            result.minAspect = stricter(result.minAspect, next.minAspect, by: max)
            result.maxAspect = stricter(result.maxAspect, next.maxAspect, by: min)
            if let types = next.mimeTypes { result.mimeTypes = result.mimeTypes.map { $0.filter(types.contains) } ?? types }
            result.modelTitles.append(next.modelTitles[0])
        }
        return result
    }

    private static func stricter(_ a: Double?, _ b: Double?, by pick: (Double, Double) -> Double) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        return pick(a, b)
    }

    /// What happens to one measured image. Only too small, too narrow, animated or unfittable images are refused.
    func decide(_ image: SkyStudioReference) -> Decision {
        let refuse = { (reason: SkyStudioReferenceFitFailure.Reason) in
            Decision.refuse(SkyStudioReferenceFitFailure(file: image.file.lastPathComponent, models: modelTitles, reason: reason))
        }
        guard let width = image.width, let height = image.height, width > 0, height > 0 else { return refuse(.unreadable) }
        let ratio = width / height
        if let low = minAspect, ratio < low { return refuse(.aspect(min: minAspect, max: maxAspect, ratio: ratio)) }
        if let high = maxAspect, ratio > high { return refuse(.aspect(min: minAspect, max: maxAspect, ratio: ratio)) }
        if let minSide, min(width, height) < minSide { return refuse(.tooSmall(minSide: minSide, width: width, height: height)) }
        var scale = 1.0
        var reasons: [String] = []
        if let maxPixels, width * height > maxPixels {
            scale = min(scale, (maxPixels / (width * height)).squareRoot())
            reasons.append("over \(Self.text(maxPixels)) pixels")
        }
        if let maxSide, max(width, height) > maxSide {
            scale = min(scale, maxSide / max(width, height))
            reasons.append("a side over \(Self.text(maxSide)) px")
        }
        let type = image.contentType ?? ""
        if let mimeTypes, !mimeTypes.contains(type) { reasons.append("\(type.isEmpty ? "its format" : type) is not one of \(mimeTypes.joined(separator: ", "))") }
        if let maxBytes, image.bytes > maxBytes { reasons.append("over \(Self.text(maxBytes)) bytes") }
        if reasons.isEmpty { return .asIs }
        if image.imageCount > 1, Self.animated.contains(type) { return refuse(.animated(frames: image.imageCount)) }
        guard size(width: width, height: height, scale: scale) != nil else {
            return refuse(.cannotFit(detail: "the pixel limits would take a side below \(Self.text(minSide ?? 0)) px"))
        }
        guard let output = outputType(type, transparent: image.hasTransparency) else {
            return refuse(.cannotFit(detail: "no format they take (\((mimeTypes ?? []).joined(separator: ", "))) can be written"))
        }
        return .fit(Plan(contentType: output, scale: scale, reasons: reasons))
    }

    /// The integer size of a copy at `scale` (at most 1, never an upscale) of a width × height picture that meets every pixel
    /// limit: the long side rounded down, the short side rounded to keep the shape, then nudged a pixel so the final integer
    /// width / height stays inside the aspect range (a 16:1 picture never becomes 16.005:1). Nil when only a side below the
    /// minimum would meet the limits.
    func size(width: Double, height: Double, scale: Double) -> (width: Int, height: Int)? {
        let landscape = width >= height
        let long = max(width, height), short = min(width, height)
        var edge = max(1, Int((long * min(scale, 1)).rounded(.down)))
        while edge >= 1 {
            let across = max(1, min(Int(short), Int((Double(edge) * short / long).rounded())))
            var w = landscape ? edge : across, h = landscape ? across : edge
            if let maxAspect, Double(w) / Double(h) > maxAspect { w = Int((Double(h) * maxAspect).rounded(.down)) }
            if let minAspect, Double(w) / Double(h) < minAspect { h = Int((Double(w) / minAspect).rounded(.down)) }
            let tooMany = maxPixels.map { Double(w * h) > $0 } ?? false
            let tooLong = maxSide.map { Double(max(w, h)) > $0 } ?? false
            if !tooMany && !tooLong {
                if let minSide, Double(min(w, h)) < minSide { return nil }
                return w >= 1 && h >= 1 ? (w, h) : nil
            }
            edge -= max(1, edge / 2000)
        }
        return nil
    }

    /// JPEG and PNG stay as they are when taken; anything else becomes PNG if it has transparency (and PNG is taken), else JPEG.
    func outputType(_ type: String, transparent: Bool) -> String? {
        let allowed = Self.writable.filter { mimeTypes?.contains($0) ?? true }
        if allowed.contains(type) { return type }
        if transparent, allowed.contains("image/png") { return "image/png" }
        return allowed.contains("image/jpeg") ? "image/jpeg" : allowed.first
    }

    /// One line per image that will be fitted, for the tool's answer: the AI tells the user before delivery. Plus one line when the
    /// images look over a total for all of them together (a copy's exact size is only known once it is written).
    static func notes(_ plan: SkyStudioReferencePlan) -> [String] {
        guard let fit = plan.fit else { return [] }
        let titles = fit.modelTitles.joined(separator: " / ")
        var notes = plan.files.compactMap { file -> String? in
            guard file.type == "image", case .fit(let how) = fit.decide(file) else { return nil }
            return "\(file.file.lastPathComponent) is fitted to the reference limits of \(titles) before upload "
                + "(\(how.reasons.joined(separator: "; "))): sent as \(how.contentType)\(how.scale < 1 ? ", downscaled" : ""); the original file is unchanged."
        }
        let images = plan.files.filter { $0.type == "image" }
        let about = images.reduce(0) { $0 + fit.uploadEstimate($1) }
        if let total = fit.maxTotalBytes, about > total {
            notes.append("Together the \(images.count) reference images come to about \(text(about.rounded())) bytes, over the \(text(total)) bytes \(titles) "
                + "take for all of them: before upload SkyCut makes the largest smaller still, as little as needed and never below a "
                + "\(text(SkyStudioReferenceTotal.floorEdge)) px long side; the original files are unchanged.")
        }
        return notes
    }

    /// About how many bytes an image goes up as after its own limits: a pixel cut shrinks it with the area, a byte limit caps it.
    func uploadEstimate(_ image: SkyStudioReference) -> Double {
        guard case .fit(let plan) = decide(image) else { return image.bytes }
        return min(image.bytes * plan.scale * plan.scale, maxBytes ?? .infinity)
    }

    /// These limits with the byte limit lowered to `bytes`: an image's share of a total for all the images together.
    func capped(_ bytes: Double) -> SkyStudioReferenceFit {
        var capped = self
        capped.maxBytes = min(maxBytes ?? bytes, bytes)
        return capped
    }

    /// The limits as one value: an upload prepared for other limits must not be reused (official prepared references).
    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        for (key, number) in [("max_bytes", maxBytes), ("max_total_bytes", maxTotalBytes), ("max_pixels", maxPixels), ("max_side", maxSide),
                              ("min_side", minSide), ("min_aspect", minAspect), ("max_aspect", maxAspect)] {
            if let number { value[key] = .number(number) }
        }
        if let mimeTypes { value["mime_types"] = .array(mimeTypes.map(JSONValue.string)) }
        return .object(value)
    }

    /// A number for messages: whole numbers grouped by thousands, others with up to four decimals.
    static func text(_ number: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = number.rounded() == number
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}

extension SkyStudioReferenceFit {
    /// The largest copy at or below scale `high` that comes under `maxBytes`, to within 1 % of scale: an estimate from
    /// √(limit / bytes) first, smaller steps until one fits, then halving the gap to the smallest size that did not. Never below
    /// `lowest` (SkyCut's floor when the images share a total): a step that would pass it, or steps that run out above it, try
    /// `lowest` itself last, so a copy that fits at the floor is always found.
    /// `encode` gives the copy at a scale, or nil when that size would break a pixel limit (a side below the minimum).
    /// Generic over the copy so the search itself is checked; the writer passes encoded images.
    static func largestFitting<Copy>(below high: Double, lowest: Double = 0, firstBytes: Int, maxBytes: Double, bytesOf: (Copy) -> Int,
                                     encode: (Double) throws -> Copy?) rethrows -> Copy? {
        var high = high
        var low = max(lowest, high * (maxBytes / Double(max(1, firstBytes))).squareRoot())
        var found: Copy?
        for _ in 0 ..< 12 where found == nil {
            guard let next = try encode(low) else { return nil }
            if Double(bytesOf(next)) <= maxBytes { found = next }
            else if low <= lowest { return nil }
            else { high = low; low = max(lowest, low * min(0.97, (maxBytes / Double(bytesOf(next))).squareRoot())) }
        }
        if found == nil, lowest > 0 {
            guard let floor = try encode(lowest), Double(bytesOf(floor)) <= maxBytes else { return nil }
            (found, low) = (floor, lowest)
        }
        guard var best = found else { return nil }
        while (high - low) / high > 0.01 {
            let middle = (low + high) / 2
            if let next = try encode(middle), Double(bytesOf(next)) <= maxBytes { best = next; low = middle } else { high = middle }
        }
        return best
    }

    /// One model's limits, when its record allows fitting; nil for an older Sky Studio, a model without `fit_images`
    /// (video models, image upscale) or one with no reference limits.
    init?(model: SkyStudioModel, mode: String) {
        guard let limits = model.referenceLimits(mode: mode), limits["fit_images"]?.boolValue == true else { return nil }
        let sides = limits["image_dimensions"] ?? limits["media_dimensions"]
        let aspect = limits["media_aspect_ratio"]
        self.init(maxBytes: limits["max_image_bytes"]?.doubleValue, maxTotalBytes: limits["max_total_image_bytes"]?.doubleValue,
                  maxPixels: limits["max_image_pixels"]?.doubleValue,
                  maxSide: sides?["max_side"]?.doubleValue, minSide: sides?["min_side"]?.doubleValue,
                  minAspect: Self.stricter(limits["min_image_aspect_ratio"]?.doubleValue, aspect?["min"]?.doubleValue, by: max),
                  maxAspect: Self.stricter(limits["max_image_aspect_ratio"]?.doubleValue, aspect?["max"]?.doubleValue, by: min),
                  mimeTypes: limits["image_mime_types"]?.arrayValue?.compactMap(\.stringValue), modelTitles: [model.title])
    }
}

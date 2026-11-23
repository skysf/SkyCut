import Foundation
import SrtFlowMCPKit

// MARK: - Fitting a reference image to the models' published limits (pure values)
// What it does: reads a model's reference-image limits from /models, but only when its record says `fit_images: true`
// (`max_image_bytes`, `max_image_pixels`, `image_dimensions` / `media_dimensions` min and max side, the aspect range,
// `image_mime_types`); merges the limits of the chosen model and its fallbacks into the strictest; and decides for one
// measured image: upload it unchanged, fit it (convert, re-encode, downscale; never upscale), or refuse it with the limit.
// Not here: pixels and files (SkyStudioReferenceImageFit), which models form the chain (SkyStudioModelPolicy.fallbacks),
// uploading (SkyStudioReferenceFiles). Every number comes from the server's catalog; none is written here.
// Rules: docs/architecture/reference-image-fitting.md.

struct SkyStudioReferenceFit: Equatable, Sendable {
    var maxBytes: Double?
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
        case refuse(String)
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

    /// What happens to one measured image. Only too small, too narrow, animated or unconvertible images are refused.
    func decide(_ image: SkyStudioReference) -> Decision {
        let name = image.file.lastPathComponent
        let models = modelTitles.joined(separator: " / ")
        guard let width = image.width, let height = image.height, width > 0, height > 0 else { return .refuse("\(name) has no readable size.") }
        let ratio = width / height
        if let low = minAspect, ratio < low {
            return .refuse("\(name) is too tall for \(models): width / height must be at least \(Self.text(low)) (it is \(Self.text(ratio))). SkyCut does not crop.")
        }
        if let high = maxAspect, ratio > high {
            return .refuse("\(name) is too wide for \(models): width / height must be at most \(Self.text(high)) (it is \(Self.text(ratio))). SkyCut does not crop.")
        }
        if let minSide, min(width, height) < minSide {
            return .refuse("\(name) is too small for \(models): each side must be at least \(Self.text(minSide)) px (it is \(Self.text(width))×\(Self.text(height))). SkyCut never upscales.")
        }
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
        if image.imageCount > 1, Self.animated.contains(type) {
            return .refuse("\(name) is animated (\(image.imageCount) frames); \(models) take one still image. Send a single frame.")
        }
        if let minSide, (min(width, height) * scale).rounded(.down) < minSide {
            return .refuse("\(name) cannot be fitted for \(models): the pixel limits would take a side below \(Self.text(minSide)) px.")
        }
        guard let output = outputType(type, transparent: image.hasTransparency) else {
            return .refuse("\(name) cannot be converted to a format \(models) take (\((mimeTypes ?? []).joined(separator: ", "))).")
        }
        return .fit(Plan(contentType: output, scale: scale, reasons: reasons))
    }

    /// JPEG and PNG stay as they are when taken; anything else becomes PNG if it has transparency (and PNG is taken), else JPEG.
    func outputType(_ type: String, transparent: Bool) -> String? {
        let allowed = Self.writable.filter { mimeTypes?.contains($0) ?? true }
        if allowed.contains(type) { return type }
        if transparent, allowed.contains("image/png") { return "image/png" }
        return allowed.contains("image/jpeg") ? "image/jpeg" : allowed.first
    }

    /// One line per image that will be fitted, for the tool's answer: the AI tells the user before delivery.
    static func notes(_ plan: SkyStudioReferencePlan) -> [String] {
        guard let fit = plan.fit else { return [] }
        return plan.files.compactMap { file in
            guard file.type == "image", case .fit(let how) = fit.decide(file) else { return nil }
            return "\(file.file.lastPathComponent) is fitted to the reference limits of \(fit.modelTitles.joined(separator: " / ")) before upload "
                + "(\(how.reasons.joined(separator: "; "))): sent as \(how.contentType)\(how.scale < 1 ? ", downscaled" : ""); the original file is unchanged."
        }
    }

    /// The limits as one value: an upload prepared for other limits must not be reused (official prepared references).
    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        for (key, number) in [("max_bytes", maxBytes), ("max_pixels", maxPixels), ("max_side", maxSide), ("min_side", minSide),
                              ("min_aspect", minAspect), ("max_aspect", maxAspect)] {
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
    /// One model's limits, when its record allows fitting; nil for an older Sky Studio, a model without `fit_images`
    /// (video models, image upscale) or one with no reference limits.
    init?(model: SkyStudioModel, mode: String) {
        guard let limits = model.referenceLimits(mode: mode), limits["fit_images"]?.boolValue == true else { return nil }
        let sides = limits["image_dimensions"] ?? limits["media_dimensions"]
        let aspect = limits["media_aspect_ratio"]
        self.init(maxBytes: limits["max_image_bytes"]?.doubleValue, maxPixels: limits["max_image_pixels"]?.doubleValue,
                  maxSide: sides?["max_side"]?.doubleValue, minSide: sides?["min_side"]?.doubleValue,
                  minAspect: Self.stricter(limits["min_image_aspect_ratio"]?.doubleValue, aspect?["min"]?.doubleValue, by: max),
                  maxAspect: Self.stricter(limits["max_image_aspect_ratio"]?.doubleValue, aspect?["max"]?.doubleValue, by: min),
                  mimeTypes: limits["image_mime_types"]?.arrayValue?.compactMap(\.stringValue), modelTitles: [model.title])
    }
}
